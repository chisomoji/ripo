
import { createHash } from "node:crypto";
import {
  Cl,
  ClarityType,
  PrincipalCV,
  ResponseOkCV,
  cvToString,
} from "@stacks/transactions";
import { describe, expect, it } from "vitest";

const contractName = "ripo";
const accounts = simnet.getAccounts();
const owner = accounts.get("deployer")!;
const userA = accounts.get("wallet_1")!;
const userB = accounts.get("wallet_2")!;
const userC = accounts.get("wallet_3")!;

const ERR = {
  HASH_MISMATCH: 1n,
  NO_COMMITMENT: 2n,
  ALREADY_REVEALED: 3n,
  COMMIT_PHASE_ENDED: 4n,
  NOT_REVEAL_PHASE: 5n,
  NOT_AUTHORIZED: 6n,
  INSUFFICIENT_PAYMENT: 7n,
  MAX_PARTICIPANTS: 8n,
  LOTTERY_NOT_FINALIZED: 9n,
  ALREADY_FINALIZED: 10n,
  NO_REVEALS: 11n,
  ALREADY_COMMITTED: 12n,
  REFUND_UNAVAILABLE: 13n,
  NO_REFUNDABLE_ENTRY: 14n,
} as const;

const ENTRY_FEE = 1_000_000n;

const nonceA = `0x${"01".repeat(32)}`;
const nonceB = `0x${"02".repeat(32)}`;
const nonceC = `0x${"03".repeat(32)}`;

const sha256Hex = (hex: string) =>
  createHash("sha256")
    .update(Buffer.from(hex.replace(/^0x/, ""), "hex"))
    .digest("hex");

const commitArg = (nonceHex: string) => Cl.bufferFromHex(sha256Hex(nonceHex));
const revealArg = (nonceHex: string) => Cl.bufferFromHex(nonceHex.replace(/^0x/, ""));

const mineBlocks = (count: number) => {
  for (let i = 0; i < count; i += 1) {
    simnet.mineBlock([]);
  }
};

const startLottery = (
  commitDuration = 4n,
  revealDuration = 4n,
  fee = ENTRY_FEE,
  maxEntries = 10n,
) =>
  simnet.callPublicFn(
    contractName,
    "start-lottery",
    [Cl.uint(commitDuration), Cl.uint(revealDuration), Cl.uint(fee), Cl.uint(maxEntries)],
    owner,
  );

describe("ripo lottery", () => {
  it("runs commit → reveal → finalize and records winner and prize", () => {
    const start = startLottery();
    expect(start.result).toBeOk(Cl.bool(true));

    const commit1 = simnet.callPublicFn(contractName, "commit", [commitArg(nonceA)], userA);
    const commit2 = simnet.callPublicFn(contractName, "commit", [commitArg(nonceB)], userB);
    expect(commit1.result).toBeOk(expect.anything());
    expect(commit2.result).toBeOk(expect.anything());

    expect(simnet.getDataVar(contractName, "entry-counter")).toBeUint(2);
    expect(simnet.getDataVar(contractName, "total-prize-pool")).toBeUint(ENTRY_FEE * 2n);

    mineBlocks(2); // move into reveal phase (commit end was set during start)

    const reveal1 = simnet.callPublicFn(contractName, "reveal", [revealArg(nonceA)], userA);
    const reveal2 = simnet.callPublicFn(contractName, "reveal", [revealArg(nonceB)], userB);
    expect(reveal1.result).toBeOk(Cl.bool(true));
    expect(reveal2.result).toBeOk(Cl.bool(true));

    mineBlocks(2); // end reveal phase

    const finalize = simnet.callPublicFn(contractName, "finalize-lottery", [], owner);
    expect(finalize.result).toHaveClarityType(ClarityType.ResponseOk);
    const winner = (finalize.result as ResponseOkCV<PrincipalCV>).value;
    const winnerAddress = cvToString(winner, "tryAscii");

    expect([userA, userB]).toContain(winnerAddress);

    const winnersEntry = simnet.getMapEntry(contractName, "winners", Cl.uint(1));
    expect(winnersEntry).toBeSome(
      Cl.tuple({
        participant: winner,
        "prize-amount": Cl.uint((ENTRY_FEE * 2n * 9n) / 10n),
      }),
    );
    expect(simnet.getDataVar(contractName, "lottery-finalized")).toBeBool(true);
  });

  it("requires owner to start lottery", () => {
    const res = simnet.callPublicFn(
      contractName,
      "start-lottery",
      [Cl.uint(1), Cl.uint(1), Cl.uint(ENTRY_FEE), Cl.uint(5)],
      userA,
    );
    expect(res.result).toBeErr(Cl.uint(ERR.NOT_AUTHORIZED));
  });

  it("prevents commits after commit phase ends", () => {
    expect(startLottery(2n, 2n).result).toBeOk(expect.anything());
    mineBlocks(1);
    const commitLate = simnet.callPublicFn(
      contractName,
      "commit",
      [commitArg(nonceA)],
      userA,
    );
    expect(commitLate.result).toBeErr(Cl.uint(ERR.COMMIT_PHASE_ENDED));
  });

  it("blocks duplicate commits from the same participant", () => {
    expect(startLottery().result).toBeOk(expect.anything());
    const first = simnet.callPublicFn(contractName, "commit", [commitArg(nonceA)], userA);
    const second = simnet.callPublicFn(contractName, "commit", [commitArg(nonceB)], userA);
    expect(first.result).toBeOk(expect.anything());
    expect(second.result).toBeErr(Cl.uint(ERR.ALREADY_COMMITTED));
  });

  it("rejects invalid reveals and double reveals", () => {
    expect(startLottery(2n, 4n).result).toBeOk(expect.anything());
    expect(simnet.callPublicFn(contractName, "commit", [commitArg(nonceA)], userA).result).toBeOk(
      expect.anything(),
    );

    mineBlocks(1); // enter reveal phase

    const wrongNonce = simnet.callPublicFn(contractName, "reveal", [revealArg(nonceB)], userA);
    expect(wrongNonce.result).toBeErr(Cl.uint(ERR.HASH_MISMATCH));

    const correct = simnet.callPublicFn(contractName, "reveal", [revealArg(nonceA)], userA);
    expect(correct.result).toBeOk(Cl.bool(true));

    const doubleReveal = simnet.callPublicFn(contractName, "reveal", [revealArg(nonceA)], userA);
    expect(doubleReveal.result).toBeErr(Cl.uint(ERR.ALREADY_REVEALED));

    expect(simnet.getDataVar(contractName, "revealed-counter")).toBeUint(1);
  });

  it("processes refunds only when no reveals occurred", () => {
    expect(startLottery(2n, 2n).result).toBeOk(expect.anything());
    expect(simnet.callPublicFn(contractName, "commit", [commitArg(nonceA)], userA).result).toBeOk(
      expect.anything(),
    );

    mineBlocks(3); // past reveal end with zero reveals

    const refund = simnet.callPublicFn(contractName, "claim-refund", [], userA);
    expect(refund.result).toBeOk(Cl.bool(true));
    expect(simnet.getDataVar(contractName, "total-prize-pool")).toBeUint(0);
    expect(
      simnet.getMapEntry(contractName, "commitments", Cl.standardPrincipal(userA)),
    ).toBeNone();
  });

  it("rejects refunds once a reveal has happened", () => {
    expect(startLottery(3n, 2n).result).toBeOk(expect.anything());
    expect(simnet.callPublicFn(contractName, "commit", [commitArg(nonceA)], userA).result).toBeOk(
      expect.anything(),
    );
    expect(simnet.callPublicFn(contractName, "commit", [commitArg(nonceB)], userB).result).toBeOk(
      expect.anything(),
    );

    mineBlocks(1); // enter reveal phase
    expect(simnet.callPublicFn(contractName, "reveal", [revealArg(nonceA)], userA).result).toBeOk(
      Cl.bool(true),
    );

    mineBlocks(2); // past reveal end

    const refund = simnet.callPublicFn(contractName, "claim-refund", [], userB);
    expect(refund.result).toBeErr(Cl.uint(ERR.REFUND_UNAVAILABLE));
  });

  it("reset-contract cleans commitments, entries, and flags", () => {
    expect(startLottery(3n, 2n).result).toBeOk(expect.anything());
    expect(simnet.callPublicFn(contractName, "commit", [commitArg(nonceA)], userA).result).toBeOk(
      expect.anything(),
    );
    expect(simnet.callPublicFn(contractName, "commit", [commitArg(nonceC)], userC).result).toBeOk(
      expect.anything(),
    );

    mineBlocks(1);
    expect(simnet.callPublicFn(contractName, "reveal", [revealArg(nonceA)], userA).result).toBeOk(
      Cl.bool(true),
    );
    mineBlocks(2);

    const reset = simnet.callPublicFn(contractName, "reset-contract", [], owner);
    expect(reset.result).toBeOk(Cl.bool(true));

    const resetStatus = simnet.callReadOnlyFn(contractName, "verify-reset-complete", [], owner);
    expect(resetStatus.result).toBeTuple({
      "phases-cleared": Cl.bool(true),
      "counters-reset": Cl.bool(true),
      "lottery-reset": Cl.bool(true),
      "participant-list-empty": Cl.bool(true),
      "reveal-state-reset": Cl.bool(true),
      "revealed-participants-empty": Cl.bool(true),
    });

    expect(
      simnet.getMapEntry(contractName, "commitments", Cl.standardPrincipal(userA)),
    ).toBeNone();
    expect(simnet.getMapEntry(contractName, "entries", Cl.uint(1))).toBeNone();
    expect(simnet.getDataVar(contractName, "lottery-finalized")).toBeBool(false);
  });
});
