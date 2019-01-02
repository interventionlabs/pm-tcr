pragma solidity ^0.4.11;

import "tokens/eip20/EIP20Interface.sol";
import "./Parameterizer.sol";
import "plcr-revival/PLCRVoting.sol";
import "zeppelin/math/SafeMath.sol";
import "./Bank.sol";

contract Registry {

    // ------
    // EVENTS
    // ------

    event _Application(bytes32 indexed listingHash, uint deposit, uint appEndDate, string data, address indexed applicant);
    event _Challenge(bytes32 indexed listingHash, uint challengeID, string data, uint commitEndDate, uint revealEndDate, address indexed challenger);
    event _Deposit(bytes32 indexed listingHash, uint added, uint newTotal, address indexed owner);
    event _Withdrawal(bytes32 indexed listingHash, uint withdrew, uint newTotal, address indexed owner);
    event _ApplicationWhitelisted(bytes32 indexed listingHash);
    event _ApplicationRemoved(bytes32 indexed listingHash);
    event _ListingRemoved(bytes32 indexed listingHash);
    event _ListingWithdrawn(bytes32 indexed listingHash);
    event _TouchAndRemoved(bytes32 indexed listingHash);
    event _ChallengeFailed(bytes32 indexed listingHash, uint indexed challengeID, uint rewardPool, uint totalTokens);
    event _ChallengeSucceeded(bytes32 indexed listingHash, uint indexed challengeID, uint rewardPool, uint totalTokens);
    event _RewardClaimed(uint indexed challengeID, uint reward, address indexed voter);
    event _InflationRewardsClaimed(uint epochNumber, uint epochTokens, uint epochInflation, uint epochInflationVoterRewards, address voter);
    event _EpochResolved(uint epochNumber, uint epochTokens, uint epochInflation, address resolver);

    using SafeMath for uint;

    struct Listing {
        uint applicationExpiry; // Expiration date of apply stage
        bool whitelisted;       // Indicates registry status
        address owner;          // Owner of Listing
        uint unstakedDeposit;   // Number of tokens in the listing not locked in a challenge
        uint challengeID;       // Corresponds to a PollID in PLCRVoting
    }

    struct Challenge {
        uint rewardPool;         // (remaining) Pool of tokens to be distributed to winning voters
        address challenger;      // Owner of Challenge
        bool resolved;           // Indication of if challenge is resolved
        uint stake;              // Number of tokens at stake for either party during challenge
        uint totalTokens;        // (remaining) Number of tokens used in voting by the winning side
        uint totalWinningTokens; // Number of tokens used in voting by the winning side
        uint epochNumber;        // Epoch number at challenge resolution
        mapping(address => bool) tokenClaims; // Indicates whether a voter has claimed a reward yet
    }

    // Maps challengeIDs to associated challenge data
    mapping(uint => Challenge) public challenges;

    // Maps listingHashes to associated listingHash data
    mapping(bytes32 => Listing) public listings;

    // Global Variables
    EIP20Interface public token;
    PLCRVoting public voting;
    Parameterizer public parameterizer;
    Bank public bank;
    string public name;

    /**
    @dev Initializer. Can only be called once.
    @param _token The address where the ERC20 token contract is deployed
    */
    function init(
        address _token,
        address _voting,
        address _parameterizer,
        string _name,
        uint _epochDuration,
        uint _inflationDenominator
    ) public {
        require(_token != 0 && address(token) == 0, "Token should currently be zero & not set to zero");
        require(_voting != 0 && address(voting) == 0, "Voting should currently be zero & not set to zero");
        require(_parameterizer != 0 && address(parameterizer) == 0, "Parameterizer should currently be zero & not set to zero");

        token = EIP20Interface(_token);
        voting = PLCRVoting(_voting);
        parameterizer = Parameterizer(_parameterizer);
        bank = new Bank(token, _epochDuration, _inflationDenominator);
        name = _name;
    }

    // --------------------
    // PUBLISHER INTERFACE:
    // --------------------

    /**
    @dev                Allows a user to start an application. Takes tokens from user and sets
                        apply stage end time.
    @param _listingHash The hash of a potential listing a user is applying to add to the registry
    @param _amount      The number of ERC20 tokens a user is willing to potentially stake
    @param _data        Extra data relevant to the application. Think IPFS hashes.
    */
    function apply(bytes32 _listingHash, uint _amount, string _data) external {
        require(!isWhitelisted(_listingHash), "Listing should not be whitelisted");
        require(!appWasMade(_listingHash), "Application should not have been made");
        require(_amount >= parameterizer.get("minDeposit"), "Amount should be greater than or equal to the minimum deposit");

        // Sets owner
        Listing storage listing = listings[_listingHash];
        listing.owner = msg.sender;

        // Sets apply stage end time
        listing.applicationExpiry = block.timestamp.add(parameterizer.get("applyStageLen"));
        listing.unstakedDeposit = _amount;

        // Transfers tokens from user to Registry contract
        require(token.transferFrom(listing.owner, this, _amount), "Should have transferred tokens from the listing owner to Registry");

        emit _Application(_listingHash, _amount, listing.applicationExpiry, _data, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to increase their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of
    @param _amount      The number of ERC20 tokens to increase a user's unstaked deposit
    */
    function deposit(bytes32 _listingHash, uint _amount) external {
        Listing storage listing = listings[_listingHash];

        require(listing.owner == msg.sender, "Listing owner should be the message sender");

        listing.unstakedDeposit += _amount;
        require(token.transferFrom(msg.sender, this, _amount), "Should have transferred tokens from the message sender to Registry");

        emit _Deposit(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to decrease their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of.
    @param _amount      The number of ERC20 tokens to withdraw from the unstaked deposit.
    */
    function withdraw(bytes32 _listingHash, uint _amount) external {
        Listing storage listing = listings[_listingHash];

        require(listing.owner == msg.sender, "Listing owner should be the message sender");
        require(_amount <= listing.unstakedDeposit, "Amount should be less than or equal to the listing's unstaked deposit");
        require(listing.unstakedDeposit - _amount >= parameterizer.get("minDeposit"));

        listing.unstakedDeposit -= _amount;
        require(token.transfer(msg.sender, _amount), "Should have transferred tokens to the message sender");

        emit _Withdrawal(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to remove the listingHash from the whitelist
                        Returns all tokens to the owner of the listingHash
    @param _listingHash A listingHash msg.sender is the owner of.
    */
    function exit(bytes32 _listingHash) external {
        Listing storage listing = listings[_listingHash];

        require(msg.sender == listing.owner, "Message sender should be the listing's owner");
        require(isWhitelisted(_listingHash), "Listing should be whitelisted");

        // Cannot exit during ongoing challenge
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved, "Listing's challengeID should be zero or challenge should be resolved");

        // Remove listingHash & return tokens
        resetListing(_listingHash);
        emit _ListingWithdrawn(_listingHash);
    }

    // -----------------------
    // TOKEN HOLDER INTERFACE:
    // -----------------------

    /**
    @dev                Starts a poll for a listingHash which is either in the apply stage or
                        already in the whitelist. Tokens are taken from the challenger and the
                        applicant's deposits are locked.
    @param _listingHash The listingHash being challenged, whether listed or in application
    @param _data        Extra data relevant to the challenge. Think IPFS hashes.
    */
    function challenge(bytes32 _listingHash, string _data) external returns (uint challengeID) {
        Listing storage listing = listings[_listingHash];
        uint minDeposit = parameterizer.get("minDeposit");

        // Listing must be in apply stage or already on the whitelist
        require(appWasMade(_listingHash) || listing.whitelisted);
        // Prevent multiple challenges
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved, "Listing's challengeID should be zero or challenge should be resolved");

        if (listing.unstakedDeposit < minDeposit) {
            // Not enough tokens, listingHash auto-delisted
            resetListing(_listingHash);
            emit _TouchAndRemoved(_listingHash);
            return 0;
        }

        // Starts poll
        uint pollID = voting.startPoll(
            parameterizer.get("voteQuorum"),
            parameterizer.get("commitStageLen"),
            parameterizer.get("revealStageLen")
        );

        uint oneHundred = 100; // Kludge that we need to use SafeMath
        challenges[pollID] = Challenge({
            challenger: msg.sender,
            rewardPool: ((oneHundred.sub(parameterizer.get("dispensationPct"))).mul(minDeposit)).div(100),
            stake: minDeposit,
            resolved: false,
            totalTokens: 0,
            totalWinningTokens: 0,
            epochNumber: 0
        });

        // Updates listingHash to store most recent challenge
        listing.challengeID = pollID;

        // Locks tokens for listingHash during challenge
        listing.unstakedDeposit -= minDeposit;

        // Takes tokens from challenger
        require(token.transferFrom(msg.sender, this, minDeposit));

        (uint commitEndDate, uint revealEndDate,,,) = voting.pollMap(pollID);

        emit _Challenge(_listingHash, pollID, _data, commitEndDate, revealEndDate, msg.sender);
        return pollID;
    }

    /**
    @dev                Updates a listingHash's status from 'application' to 'listing' or resolves
                        a challenge if one exists.
    @param _listingHash The listingHash whose status is being updated
    */
    function updateStatus(bytes32 _listingHash) public {
        if (canBeWhitelisted(_listingHash)) {
            whitelistApplication(_listingHash);
        } else if (challengeCanBeResolved(_listingHash)) {
            resolveChallenge(_listingHash);
        } else {
            revert();
        }
    }

    /**
    @dev                  Updates an array of listingHashes' status from 'application' to 'listing' or resolves
                          a challenge if one exists.
    @param _listingHashes The listingHashes whose status are being updated
    */
    function updateStatuses(bytes32[] _listingHashes) public {
        // loop through arrays, revealing each individual vote values
        for (uint i = 0; i < _listingHashes.length; i++) {
            updateStatus(_listingHashes[i]);
        }
    }

    // ----------------
    // TOKEN FUNCTIONS:
    // ----------------

    /**
    @dev                Called by a voter to claim their reward for each completed vote. Someone
                        must call updateStatus() before this can be called.
    @param _challengeID The PLCR pollID of the challenge a reward is being claimed for
    @param _salt        The salt of a voter's commit hash in the given poll
    */
    function claimReward(uint _challengeID, uint _salt) public {
        Challenge storage challengeInstance = challenges[_challengeID];
        // Ensures the voter has not already claimed tokens and challenge results have been processed
        require(challengeInstance.tokenClaims[msg.sender] == false);
        require(challengeInstance.resolved == true);

        uint voterTokens = voting.getNumPassingTokens(msg.sender, _challengeID, _salt);
        uint reward = voterReward(msg.sender, _challengeID, _salt);

        // Subtracts the voter's information to preserve the participation ratios
        // of other voters compared to the remaining pool of rewards
        challengeInstance.totalTokens -= voterTokens;
        challengeInstance.rewardPool -= reward;
        // Ensures a voter cannot claim tokens again
        challengeInstance.tokenClaims[msg.sender] = true;

        // If the user’s vote is revealed in the majority voting faction,
        // the TCR adds the user’s revealed token weight to that user’s tally for the epoch.
        require(bank.addVoterRewardTokens(challengeInstance.epochNumber, msg.sender, voterTokens));

        // transfers reward to the voter
        require(token.transfer(msg.sender, reward));
        emit _RewardClaimed(_challengeID, reward, msg.sender);
    }

    /**
    @dev                 Called by a voter to claim their rewards for each completed vote. Someone
                         must call updateStatus() before this can be called.
    @param _challengeIDs The PLCR pollIDs of the challenges rewards are being claimed for
    @param _salts        The salts of a voter's commit hashes in the given polls
    */
    function claimRewards(uint[] _challengeIDs, uint[] _salts) public {
        // make sure the array lengths are the same
        require(_challengeIDs.length == _salts.length);

        // loop through arrays, claiming each individual vote reward
        for (uint i = 0; i < _challengeIDs.length; i++) {
            claimReward(_challengeIDs[i], _salts[i]);
        }
    }

    /**
    @dev            Claims inflation rewards earned by a voter during a challenge epoch
    @notice         The first time the bank is invoked for some epoch, the bank resolves the epoch,
                    then transfers the appropriate inflation amount,
    @param _pollID  The PLCR pollID of the challenge inflation rewards are being claimed for
    */
    function claimInflationRewards(uint _pollID) public {
        uint epochNumber = challenges[_pollID].epochNumber;
        (uint epochTokens, uint epochInflation, bool resolved) = bank.getEpochDetails(epochNumber);

        // if epoch has not been resolved, resolve the epoch,
        //  -> calculate the epoch.inflation, store it,
        //  -> transfer the epoch.inflation from Bank -> this
        // NOTE: Gas is 3x expensive for an epoch resolver (126295 vs 47102)
        if (!resolved && (epochInflation == 0)) {
            epochInflation = bank.resolveEpochInflationTransfer(epochNumber);
            // emit event here because we have access to msg.sender (resolver)
            emit _EpochResolved(epochNumber, epochTokens, epochInflation, msg.sender);
        }

        // (epoch.voterTokens[msg.sender] * epoch.inflation) / epoch.tokens
        uint epochInflationVoterRewards = bank.getEpochInflationVoterRewards(epochNumber, msg.sender);
        require(epochInflationVoterRewards > 0, "Epoch inflation voter reward is 0");

        require(token.transfer(msg.sender, epochInflationVoterRewards), "Failed to transfer epoch inflation voter rewards");
        emit _InflationRewardsClaimed(epochNumber, epochTokens, epochInflation, epochInflationVoterRewards, msg.sender);
    }

    // --------
    // GETTERS:
    // --------

    /**
    @dev                Calculates the provided voter's token reward for the given poll.
    @param _voter       The address of the voter whose reward balance is to be returned
    @param _challengeID The pollID of the challenge a reward balance is being queried for
    @param _salt        The salt of the voter's commit hash in the given poll
    @return             The uint indicating the voter's reward
    */
    function voterReward(address _voter, uint _challengeID, uint _salt)
    public view returns (uint) {
        uint totalTokens = challenges[_challengeID].totalTokens;
        uint rewardPool = challenges[_challengeID].rewardPool;
        uint voterTokens = voting.getNumPassingTokens(_voter, _challengeID, _salt);
        return (voterTokens * rewardPool) / totalTokens;
    }

    /**
    @dev                        Determines whether the given listingHash be whitelisted.
    @param _listingHash         The listingHash whose status is to be examined
    */
    function canBeWhitelisted(bytes32 _listingHash) public view returns (bool) {
        uint challengeID = listings[_listingHash].challengeID;

        // Ensures that the application was made,
        // the application period has ended,
        // the listingHash can be whitelisted,
        // and either: the challengeID == 0, or the challenge has been resolved.
        if (
            appWasMade(_listingHash) &&
            listings[_listingHash].applicationExpiry < now &&
            !isWhitelisted(_listingHash) &&
            (challengeID == 0 || challenges[challengeID].resolved == true)
        ) { return true; }

        return false;
    }

    /**
    @dev                    Returns true if the provided listingHash is whitelisted
    @param _listingHash     The listingHash whose status is to be examined
    */
    function isWhitelisted(bytes32 _listingHash) public view returns (bool whitelisted) {
        return listings[_listingHash].whitelisted;
    }

    /**
    @dev                    Returns true if apply was called for this listingHash
    @param _listingHash     The listingHash whose status is to be examined
    */
    function appWasMade(bytes32 _listingHash) public view returns (bool exists) {
        return listings[_listingHash].applicationExpiry > 0;
    }

    /**
    @dev                    Returns true if the application/listingHash has an unresolved challenge
    @param _listingHash     The listingHash whose status is to be examined
    */
    function challengeExists(bytes32 _listingHash) public view returns (bool) {
        uint challengeID = listings[_listingHash].challengeID;

        return (listings[_listingHash].challengeID > 0 && !challenges[challengeID].resolved);
    }

    /**
    @dev                    Determines whether voting has concluded in a challenge for a given listingHash.
                            Throws if no challenge exists.
    @param _listingHash     A listingHash with an unresolved challenge
    */
    function challengeCanBeResolved(bytes32 _listingHash) public view returns (bool) {
        uint challengeID = listings[_listingHash].challengeID;

        require(challengeExists(_listingHash));

        return voting.pollEnded(challengeID);
    }

    /**
    @dev                    Determines the number of tokens awarded to the winning party in a challenge.
    @param _challengeID     The challengeID to determine a reward for
    */
    function determineReward(uint _challengeID) public view returns (uint) {
        require(!challenges[_challengeID].resolved && voting.pollEnded(_challengeID));

        // Edge case, nobody voted, give all tokens to the challenger.
        if (voting.getTotalNumberOfTokensForWinningOption(_challengeID) == 0) {
            return 2 * challenges[_challengeID].stake;
        }

        return (2 * challenges[_challengeID].stake) - challenges[_challengeID].rewardPool;
    }

    /**
    @dev                    Getter for Challenge tokenClaims mappings.
    @param _challengeID     The challengeID to query
    @param _voter           The voter whose claim status to query for the provided challengeID
    */
    function tokenClaims(uint _challengeID, address _voter) public view returns (bool) {
        return challenges[_challengeID].tokenClaims[_voter];
    }

    // ----------------
    // PRIVATE FUNCTIONS:
    // ----------------

    /**
    @dev                    Determines the winner in a challenge. Rewards the winner tokens and
                            either whitelists or de-whitelists the listingHash.
    @param _listingHash     A listingHash with a challenge that is to be resolved
    */
    function resolveChallenge(bytes32 _listingHash) private {
        uint challengeID = listings[_listingHash].challengeID;
        Challenge storage challenge = challenges[challengeID];

        // Calculates the winner's reward,
        // which is: (winner's full stake) + (dispensationPct * loser's stake)
        uint reward = determineReward(challengeID);

        // Sets flag on challenge being processed
        challenge.resolved = true;

        uint totalWinningTokens = voting.getTotalNumberOfTokensForWinningOption(challengeID);
        challenge.totalWinningTokens = totalWinningTokens;
        // Stores the total tokens used for voting by the winning side for reward purposes
        challenge.totalTokens = totalWinningTokens;

        // store the current epoch
        challenge.epochNumber = bank.getCurrentEpochNumber();
        // add the totalWinningTokens to the epoch's total tokens tally
        require(bank.addChallengeWinningTokens(challenge.epochNumber, totalWinningTokens));

        // Case: challenge failed
        if (voting.isPassed(challengeID)) {
            whitelistApplication(_listingHash);
            // Unlock stake so that it can be retrieved by the applicant
            listings[_listingHash].unstakedDeposit += reward;

            emit _ChallengeFailed(_listingHash, challengeID, challenge.rewardPool, challenge.totalTokens);
        }
        // Case: challenge succeeded or nobody voted
        else {
            resetListing(_listingHash);
            // Transfer the reward to the challenger
            require(token.transfer(challenge.challenger, reward));

            emit _ChallengeSucceeded(_listingHash, challengeID, challenge.rewardPool, challenge.totalTokens);
        }
    }

    /**
    @dev                    Called by updateStatus() if the applicationExpiry date passed without a
                            challenge being made. Called by resolveChallenge() if an
                            application/listing beat a challenge.
    @param _listingHash     The listingHash of an application/listingHash to be whitelisted
    */
    function whitelistApplication(bytes32 _listingHash) private {
        if (!listings[_listingHash].whitelisted) { emit _ApplicationWhitelisted(_listingHash); }
        listings[_listingHash].whitelisted = true;
    }

    /**
    @dev                    Deletes a listingHash from the whitelist and transfers tokens back to owner
    @param _listingHash     The listing hash to delete
    */
    function resetListing(bytes32 _listingHash) private {
        Listing storage listing = listings[_listingHash];

        // Emit events before deleting listing to check whether is whitelisted
        if (listing.whitelisted) {
            emit _ListingRemoved(_listingHash);
        } else {
            emit _ApplicationRemoved(_listingHash);
        }

        // Deleting listing to prevent reentry
        address owner = listing.owner;
        uint unstakedDeposit = listing.unstakedDeposit;
        delete listings[_listingHash];
        
        // Transfers any remaining balance back to the owner
        if (unstakedDeposit > 0){
            require(token.transfer(owner, unstakedDeposit));
        }
    }
}
