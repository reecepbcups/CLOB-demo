// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ITypes} from "interfaces/ITypes.sol";
import {IMerkler} from "interfaces/merkle/IMerkler.sol";
import {IMerkleSnapshot} from "interfaces/merkle/IMerkleSnapshot.sol";
import {IMerkleSnapshotHook} from "interfaces/merkle/IMerkleSnapshotHook.sol";
import {UniqueEnvelope} from "./UniqueEnvelope.sol";

/// @title MerkleSnapshot - Merkle tree snapshotter that can be used by other contracts to verify merkle proofs and access history
/// @dev Implements IWavsServiceHandler for merkle root updates via WAVS
contract MerkleSnapshot is
    IMerkleSnapshot,
    IWavsServiceHandler,
    ITypes,
    IMerkler,
    UniqueEnvelope
{
    /// @notice Service manager for WAVS integration
    IWavsServiceManager private _serviceManager;

    /// @notice The next trigger ID
    uint64 public nextTriggerId = 1;

    /// @notice The last cron timestamp seen
    uint64 public lastCronTimestampSeen;

    /// @notice Historical merkle states, keyed by index
    mapping(uint256 stateIndex => MerkleState state) public states;

    /// @notice Array of block numbers where states were created (ascending)
    /// @dev Used for efficient binary search of historical states
    uint256[] public stateBlocks;

    /// @notice Mapping from block number to state index for efficient lookups
    /// @dev Only one state per block is allowed
    mapping(uint256 blockNumber => uint256 stateIndex) public blockToStateIndex;

    /// @notice Array of contracts to execute when the merkle state is updated.
    mapping(uint256 hookIndex => IMerkleSnapshotHook hook) public hooks;
    /// @notice Mapping from hook to hook index for efficient removal.
    mapping(IMerkleSnapshotHook hook => uint256 hookIndex) public hookIndex;
    /// @notice The next hook index to use. Start at 1 since 0 is the default value in the mappings above.
    uint64 public nextHookIndex = 1;
    /// @notice The number of hooks.
    uint64 public hookCount;

    constructor(IWavsServiceManager serviceManager) {
        _serviceManager = serviceManager;
    }

    /// @notice Trigger the Merkler AVS
    /// @return triggerId The ID of the trigger
    function trigger() external returns (uint64 triggerId) {
        // Get and increment the trigger ID.
        triggerId = nextTriggerId++;

        // Emit the trigger event.
        emit MerklerTrigger(triggerId);
    }

    /// @notice Update the state at the current block, overriding the existing state for this block if it exists
    /// @param root The merkle root
    /// @param ipfsHash The IPFS hash
    /// @param ipfsHashCid The IPFS hash CID
    function _updateState(
        bytes32 root,
        bytes32 ipfsHash,
        string memory ipfsHashCid
    ) internal {
        uint256 currentBlock = block.number;
        uint256 stateIndex;

        // If this is a new block, add it.
        if (
            stateBlocks.length == 0 ||
            stateBlocks[stateBlocks.length - 1] != currentBlock
        ) {
            stateIndex = stateBlocks.length;
            blockToStateIndex[currentBlock] = stateIndex;
            stateBlocks.push(currentBlock);
        } else {
            // If this is an existing block, override the existing state.
            stateIndex = blockToStateIndex[currentBlock];
        }

        states[stateIndex] = MerkleState({
            blockNumber: currentBlock,
            root: root,
            ipfsHash: ipfsHash,
            ipfsHashCid: ipfsHashCid
        });

        // Call the hooks.
        for (uint256 i = 1; i < nextHookIndex; i++) {
            if (hooks[i] == IMerkleSnapshotHook(address(0))) {
                continue;
            }
            hooks[i].onMerkleUpdate(states[stateIndex]);
        }
    }

    /// @notice Verify a merkle proof for a given root and account
    /// @param root The merkle root
    /// @param account The account to verify the proof for
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @return valid Whether the proof is valid
    function _verifyProof(
        bytes32 root,
        address account,
        uint256 value,
        bytes32[] calldata proof
    ) internal pure returns (bool) {
        // solhint-disable-next-line
        bytes32 leaf = keccak256(
            bytes.concat(keccak256(abi.encode(account, value)))
        );
        return MerkleProof.verifyCalldata(proof, root, leaf);
    }

    /// @notice Verify a merkle proof for a given account with the latest state
    /// @param account The account to verify the proof for
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @return valid Whether the proof is valid
    function verifyProof(
        address account,
        uint256 value,
        bytes32[] calldata proof
    ) public view returns (bool) {
        return _verifyProof(getLatestState().root, account, value, proof);
    }

    /// @notice Verify a merkle proof for the sender with the latest state
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @return valid Whether the proof is valid
    function verifyMyProof(
        uint256 value,
        bytes32[] calldata proof
    ) public view returns (bool) {
        return verifyProof(msg.sender, value, proof);
    }

    /// @notice Verify a merkle proof against the state at a specific block number
    /// @param account The account to verify the proof for
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @param blockNumber The maximum block number to consider
    /// @return valid Whether the proof is valid
    function verifyProofAtBlock(
        address account,
        uint256 value,
        bytes32[] calldata proof,
        uint256 blockNumber
    ) public view returns (bool) {
        MerkleState memory state = getStateAtBlock(blockNumber);
        return _verifyProof(state.root, account, value, proof);
    }

    /// @notice Verify a merkle proof for the sender against the state at a specific block number
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @param blockNumber The maximum block number to consider
    /// @return valid Whether the proof is valid
    function verifyMyProofAtBlock(
        uint256 value,
        bytes32[] calldata proof,
        uint256 blockNumber
    ) public view returns (bool) {
        return verifyProofAtBlock(msg.sender, value, proof, blockNumber);
    }

    /// @notice Verify a merkle proof against the state at a specific index
    /// @param account The account to verify the proof for
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @param stateIndex The state index to verify against
    /// @return valid Whether the proof is valid
    function verifyProofAtStateIndex(
        address account,
        uint256 value,
        bytes32[] calldata proof,
        uint256 stateIndex
    ) public view returns (bool) {
        MerkleState memory state = getStateAtIndex(stateIndex);
        return _verifyProof(state.root, account, value, proof);
    }

    /// @notice Verify a merkle proof for the sender against the state at a specific index
    /// @param value The value to verify
    /// @param proof The merkle proof
    /// @param stateIndex The state index to verify against
    /// @return valid Whether the proof is valid
    function verifyMyProofAtStateIndex(
        uint256 value,
        bytes32[] calldata proof,
        uint256 stateIndex
    ) public view returns (bool) {
        return verifyProofAtStateIndex(msg.sender, value, proof, stateIndex);
    }

    function getLatestState() public view returns (MerkleState memory) {
        if (stateBlocks.length == 0) {
            revert NoMerkleStates();
        }
        return states[stateBlocks.length - 1];
    }

    /// @notice Get the state at (or before) a specific block number
    /// @param blockNumber The target block number
    /// @return state The merkle state at (or before) the specified block
    function getStateAtBlock(
        uint256 blockNumber
    ) public view returns (MerkleState memory state) {
        if (stateBlocks.length == 0) {
            revert NoMerkleStates();
        }

        // If we have a direct match, return it. Since a 0 index may refer to an unset state or the first state, we need to check that the state at the direct index has the requested block number. An unset state will have a block number of 0, which is invalid.
        uint256 directIndex = blockToStateIndex[blockNumber];
        if (stateBlocks[directIndex] == blockNumber) {
            return states[directIndex];
        }

        // Binary search for the latest state at (or before) the target block
        (bool found, uint256 stateIndex) = _findStateIndexAtOrBeforeBlock(
            blockNumber
        );
        if (!found) {
            revert NoMerkleStateAtBlock(blockNumber, stateBlocks[0]);
        }
        return states[stateIndex];
    }

    /// @notice Get the state at a specific index
    /// @param index The state index
    /// @return state The merkle state at the specified index
    function getStateAtIndex(
        uint256 index
    ) public view returns (MerkleState memory state) {
        if (index >= stateBlocks.length) {
            revert NoMerkleStateAtIndex(index, stateBlocks.length);
        }
        return states[index];
    }

    /// @notice Binary search to find the state index at (or before) a given block
    /// @param blockNumber The target block number
    /// @return found Whether the state index was found
    /// @return index The state index
    function _findStateIndexAtOrBeforeBlock(
        uint256 blockNumber
    ) internal view returns (bool found, uint256 index) {
        uint256 left = 0;
        uint256 right = stateBlocks.length;
        uint256 result = 0;
        bool foundResult = false;

        while (left < right) {
            uint256 mid = (left + right) / 2;
            uint256 midBlock = stateBlocks[mid];

            if (midBlock == blockNumber) {
                // Exact match found, return immediately.
                return (true, blockToStateIndex[midBlock]);
            } else if (midBlock < blockNumber) {
                result = blockToStateIndex[midBlock];
                foundResult = true;
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        return (foundResult, result);
    }

    /// @notice Get the total number of states
    /// @return count The number of states
    function getStateCount() public view returns (uint256 count) {
        return stateBlocks.length;
    }

    /// @notice Get paginated block numbers that have states
    /// @param offset The offset to start from
    /// @param limit The number of blocks to return
    /// @return result_ Array of block numbers with states
    function getStateBlocks(
        uint256 offset,
        uint256 limit
    ) public view returns (uint256[] memory result_) {
        uint256 end = offset + limit;
        if (end > stateBlocks.length) {
            end = stateBlocks.length;
        }

        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = stateBlocks[i];
        }
        return result;
    }

    /// @notice Get paginated states
    /// @param offset The offset to start from
    /// @param limit The number of blocks to return
    /// @return result_ Array of states
    function getStates(
        uint256 offset,
        uint256 limit
    ) public view returns (MerkleState[] memory result_) {
        uint256 end = offset + limit;
        if (end > stateBlocks.length) {
            end = stateBlocks.length;
        }

        MerkleState[] memory result = new MerkleState[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = states[i];
        }
        return result;
    }

    /////////////////////////////////////////////////////////////////
    // HOOKS
    /////////////////////////////////////////////////////////////////

    /// @notice Add a hook
    function addHook(IMerkleSnapshotHook hook) external {
        if (hookIndex[hook] != 0) {
            revert HookAlreadyAdded();
        }

        hooks[nextHookIndex] = hook;
        hookIndex[hook] = nextHookIndex;
        nextHookIndex++;
        hookCount++;
    }

    /// @notice Remove a hook
    function removeHook(IMerkleSnapshotHook hook) external {
        if (hookIndex[hook] == 0) {
            revert HookNotAdded();
        }

        delete hooks[hookIndex[hook]];
        delete hookIndex[hook];
        hookCount--;
    }

    /// @notice List all hooks
    function getHooks() external view returns (IMerkleSnapshotHook[] memory) {
        IMerkleSnapshotHook[] memory result = new IMerkleSnapshotHook[](
            hookCount
        );
        uint256 resultIndex = 0;
        for (uint256 i = 1; i < nextHookIndex; i++) {
            if (hooks[i] == IMerkleSnapshotHook(address(0))) {
                continue;
            }
            result[resultIndex] = hooks[i];
            resultIndex++;
        }
        return result;
    }

    /*///////////////////////////////////////////////////////////////
                          WAVS INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWavsServiceHandler
    function handleSignedEnvelope(
        Envelope calldata envelope,
        SignatureData calldata signatureData
    ) external {
        _serviceManager.validate(envelope, signatureData);

        // Decode payload.
        MerklerAvsOutput memory avsOutput = abi.decode(
            envelope.payload,
            (MerklerAvsOutput)
        );

        // Validate unique envelope.
        _validateUniqueEnvelope(envelope, avsOutput.expiresAt);

        // If prune is set, prune expired envelopes and return.
        if (avsOutput.prune > 0) {
            _pruneExpiredEnvelopes(avsOutput.prune);
            return;
        }

        // Update merkle root
        _updateState(avsOutput.root, avsOutput.ipfsHash, avsOutput.ipfsHashCid);

        emit MerkleRootUpdated(
            avsOutput.root,
            avsOutput.ipfsHash,
            avsOutput.ipfsHashCid
        );
    }

    /**
     * @notice Get the service manager address
     * @return address The address of the service manager
     */
    function getServiceManager() external view returns (address) {
        return address(_serviceManager);
    }
}
