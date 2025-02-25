// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract CentralizedOracleData {
    /*
     *  Events
     */
    event OwnerReplacement(address indexed newOwner);
    event OutcomeAssignment(int256 outcome);

    /*
     *  Storage
     */
    address public owner;
    bytes public ipfsHash;
    bool public isSet;
    int256 public outcome;

    /*
     *  Modifiers
     */
    modifier isOwner() {
        // Only owner is allowed to proceed
        require(msg.sender == owner);
        _;
    }
}

contract CentralizedOracleProxy is CentralizedOracleData {
    /// @dev Constructor sets owner address and IPFS hash
    /// @param _ipfsHash Hash identifying off chain event description
    constructor(address _owner, bytes memory _ipfsHash) {
        // Description hash cannot be null
        require(_ipfsHash.length == 46);
        owner = _owner;
        ipfsHash = _ipfsHash;
    }
}

/// @title Centralized oracle contract - Allows the contract owner to set an outcome
/// @author Stefan George - <stefan@gnosis.pm>
contract CentralizedOracle is CentralizedOracleData {
    /*
     *  Public functions
     */
    /// @dev Replaces owner
    /// @param newOwner New owner
    function replaceOwner(address newOwner) public isOwner {
        // Result is not set yet
        require(!isSet);
        owner = newOwner;
        emit OwnerReplacement(newOwner);
    }

    /// @dev Sets event outcome
    /// @param _outcome Event outcome
    function setOutcome(int256 _outcome) public isOwner {
        // Result is not set yet
        require(!isSet);
        isSet = true;
        outcome = _outcome;
        emit OutcomeAssignment(_outcome);
    }

    /// @dev Returns if winning outcome is set
    /// @return Is outcome set?
    function isOutcomeSet() public view returns (bool) {
        return isSet;
    }

    /// @dev Returns outcome
    /// @return Outcome
    function getOutcome() public view returns (int256) {
        return outcome;
    }
}