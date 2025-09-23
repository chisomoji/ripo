# Ripo Smart Contract

A Clarity smart contract implementing a secure commit-reveal scheme on the Stacks blockchain.

## Features

- **Phase Management**: Two-phase commit-reveal process with configurable durations
- **Access Control**: Contract owner privileges for phase management
- **State Management**: Maintains commitment records and phase transitions
- **Security**: Prevents double reveals and ensures hash integrity

## Core Functions

### Public Functions
- `start-commit-phase`: Initializes new commit-reveal rounds
- `commit`: Allows users to submit commitments
- `reveal`: Enables users to reveal their committed values
- `reset-contract`: Clears contract state between rounds

### Read-Only Functions
- `get-current-phase`: Returns current phase ("commit", "reveal", or "ended")
- `get-commitment`: Retrieves commitment data for a specific user
- `get-phase-info`: Provides phase timing information

## Data Structures

- `commitments`: Maps principals to their commitments and reveal status
- `entries`: Maps uint to participant and ticket data
- `commit-phase-end`: Block height when commit phase ends
- `reveal-phase-end`: Block height when reveal phase ends

## Error Handling

Pre-defined error codes for common failure scenarios:
- Hash mismatches
- Missing commitments
- Unauthorized access
- Phase violations
- Double reveal attempts
