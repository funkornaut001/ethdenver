// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol"; // used for the required collections check
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./BlackListManager.sol";

/// @title H2H competitions
/// @author Luis Pando
/// @notice It consumes VRF v2 from Chainlink. It has the role
/// "operator" that is the one used by a backend app to make some calls
/// @dev It saves in an ordered array the player wallet and the current
/// entries count. So buying entries has a complexity of O(1)
/// For calculating the winner, from the huge random number generated by Chainlink
/// a normalized random is generated by using the module method, adding 1 to have
/// a random from 1 to entriesCount.
/// So next step is to perform a binary search on the ordered array to get the
/// player O(log n)
/// Example:
/// 0 -> { 1, player1} as player1 buys 1 entry
/// 1 -> {51, player2} as player2 buys 50 entries
/// 2 -> {52, player3} as player3 buys 1 entry
/// 3 -> {53, player4} as player4 buys 1 entry
/// 4 -> {153, player5} as player5 buys 100 entries
/// So the setWinner method performs a binary search on that sorted array to get the upper bound.
/// If the random number generated is 150, the winner is player5. If the random number is 20, winner is player2
///
/// There are 3 possible scenarios for a competition
/// -SCENARIO 1. If there are enough players, it calls chainlink VRF v2 to get a winner
/// that takes all.
/// -SCENARIO 2. If there are players, but not enough, the first one will get unfulfilledAmount
/// (for example 0.6 ETH) instead of the amount entered to buy (for example 0.55 ETH).
/// The rest of the players get the amount entered to buy (0.55 ETH) so there is an incentive
/// to be the first to participate. It is designed to allow n participants, not only 2.
/// The contract must have some ETH in the balance to cover the difference between the amount used
/// to buy and the failureAmount (0.05 ETH in this competition).
/// But there is no need to call stake, just transfer ETH to the contract
/// -SCENARIO 3. If there are no players at all, the competition is canceled, and no fund is sent
/// to anyone
/// In scenario 1, the status of the competition is ENDED. In scenario 2 is UNFULFILLED and in 3,
/// the status of the competition is CANCELED
contract H2HVRF2 is
    AccessControl,
    ReentrancyGuard,
    VRFConsumerBaseV2,
    ConfirmedOwner
{
    ////////// CHAINLINK VRF v2 /////////////////

    VRFCoordinatorV2Interface COORDINATOR;

    // Your subscription ID.
    uint64 immutable s_subscriptionId;

    // Goerli coordinator. For other networks,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    address immutable vrfCoordinator; // = 0x2Ca8E0C643bDe4C2E08ab1fA0da3401AdAD7734D;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf-contracts/#configurations
    bytes32 immutable keyHash; // = 0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 300000;

    // The default is 3, but you can set this higher.
    uint16 immutable requestConfirmations = 3;

    // Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
    uint32 immutable numWords = 5;

    address s_owner;

    uint256 internal fee; // fee paid in LINK to chainlink. 0.1 in Rinkeby, 2 in mainnet

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords; // array with random numbers generated
        uint256 id; // competition Id
        uint256 size; // number of players
    }
    mapping(uint256 => RequestStatus) public s_requests;

    /////////////// END CHAINKINK VRF V2 //////////////

    // event sent when the smart contract calls Chainlink´s VRF v2 to generate a set of random numbers
    event RandomNumberRequested(uint256 indexed raffleId, uint256 size);

    // event sent when the random number is generated by the VRF. In SCENARIO 1 so there is a winner
    event RandomNumberCreated(
        uint256 indexed idFromMetawin,
        uint256 randomNumber,
        uint256 normalizedRandomNumber
    );

    // Event generated in SCENARIO 2, when there are players but not enough so no winner is selected
    // so players are refunded except the first player to buy, who gets an extra
    event RaffleUnfulfilled(
        uint256 indexed raffleId,
        address winner,
        uint256 unfunfilledAmount,
        uint256 randomNumber,
        uint256 amountRaised
    );
    struct RaffleInfo {
        uint256 id; // raffleId
        uint256 size; // length of the entries array of that raffle
    }

    // Event sent when the raffle is created by the operator
    event RaffleCreated(uint256 indexed raffleId, uint256 indexed prizeAmount);
    // Event sent when the raffle is finished (either early cashout or successful completion)
    event RaffleEnded(
        uint256 indexed raffleId,
        address indexed winner,
        uint256 amountRaised,
        uint256 randomNumber
    );
    // Event sent when one or more entries are sold (info from the price structure)
    event EntrySold(
        uint256 indexed raffleId,
        address indexed buyer,
        uint256 currentSize,
        uint256 priceStructureId
    );
    // Event sent when a free entry is added by the hamburguer
    event FreeEntry(
        uint256 indexed raffleId,
        address[] buyer,
        uint256 amount,
        uint256 currentSize
    );
    // Event sent when a raffle is asked to cancel by the operator
    event RaffleCancelled(uint256 indexed raffleId, uint256 amountRaised);
    // The raffle is closed successfully and the platform receives the fee
    event FeeTransferredToPlatform(
        uint256 indexed raffleId,
        uint256 amountTransferred
    );
    event SetWinnerTriggered(uint256 indexed raffleId, uint256 amountRaised);
    // Emitted when an entry is cancelled
    event EntryCancelled(
        uint256 indexed raffleId,
        uint256 amountOfEntriesCanceled,
        address player
    );

    // In order to calculate the winner, in this struct is saved for each bought the data
    struct EntriesBought {
        uint256 currentEntriesLength; // current amount of entries bought in the raffle
        address player; // wallet address of the player
    }
    // every raffle has a sorted array of EntriesBought. Each element is created when calling
    // either buyEntry or giveBatchEntriesForFree
    mapping(uint256 => EntriesBought[]) public entriesList;

    // Main raffle data struct
    struct RaffleStruct {
        STATUS status; // status of the raffle. Can be created, accepted, ended, etc
        uint48 totalEntriesCap;
        uint48 randomNumber; // normalized (0-Entries array size) random number generated by the VRF
        uint48 entriesLength; // to easy frontend, the length of the entries array is saved here
        uint48 cancellingDate;
        address[] collectionWhitelist; // addresses of the required nfts. Will be empty if no NFT is required to buy
        address winner; // address of thed winner of the raffle. Address(0) if no winner yet
        ENTRY_TYPE entryType;
        uint128 unfulfilledAmount; // amount paid to the first player that bought if the compt is canceled
        uint128 price; // price to pay to buy a single entry
        uint128 amountOfETH; // Amount of ETH of the prize
        uint128 amountRaised; // funds raised so far in wei
    }
    // The main structure is an array of raffles
    RaffleStruct[] public raffles;

    // Map that contains the number of entries each user has bought, to prevent abuse
    /*  struct ClaimStruct {
        uint48 numEntriesPerUser;
    }*/
    mapping(bytes32 => bool) public claimsData;

    // Map with the addresses linked to a particular raffle + nft
    mapping(bytes32 => address) public requiredNFTWallets;

    // All the different status a competition can have
    enum STATUS {
        CREATED, // the operator creates the raffle
        ACCEPTED, // the seller stakes the ETH for the raffle
        EARLY_CASHOUT, // the seller wants to cashout early
        CANCELLED, // the operator cancels the raffle and transfer the remaining funds after 30 days passes
        CLOSING_REQUESTED, // the operator sets a winner
        ENDED, // the raffle is finished, and the funds were transferred
        CANCEL_REQUESTED, // operator asks to cancel the raffle. Players has 30 days to ask for a refund
        UNFULFILLED // there are players, but not enough. First player that bought get an extra as incentive
    }

    enum ENTRY_TYPE {
        ONLY_DIRECTLY,
        ONLY_EXTERNAL_CONTRACT,
        MIXED
    }

    // The operator role is operated by a backend application
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");
    // requested by Hamburger. Role for the buy method of the hamburger (only that contract)
    bytes32 public constant MINTERCONTRACT_ROLE = keccak256("MINTERCONTRACT");

    // address of the wallet controlled by the platform that will receive the platform fee
    address payable public destinationWallet =
        payable(0x52a032cF59eA274f9D745f29b6D514fe95Ba192D);

    // contract that contains the black list
    BlackListManager blackListManager;

    constructor(
        address _blacklistManager,
        uint64 subscriptionId,
        address _vrfCoordinator,
        bytes32 _keyHash
    ) VRFConsumerBaseV2(_vrfCoordinator) ConfirmedOwner(msg.sender) {
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        vrfCoordinator = _vrfCoordinator;
        keyHash = _keyHash;
        s_owner = msg.sender;
        s_subscriptionId = subscriptionId;

        _setupRole(OPERATOR_ROLE, 0x13503B622abC0bD30A7e9687057DF6E8c42Fb928);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);

        blackListManager = BlackListManager(_blacklistManager);
    }

    /// @dev this is the method that will be called by the smart contract to get a random number
    /// @param _id Id of the raffle
    /// @param _entriesSize length of the entries array of that raffle
    function getRandomNumber(uint256 _id, uint256 _entriesSize)
        internal
        returns (uint256 requestId)
    {
        // Will revert if subscription is not set and funded.
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );

        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false,
            id: _id,
            size: _entriesSize /*,
            randomizedNumber: 0*/
        });

        emit RandomNumberRequested(_id, _entriesSize);

        /*     requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);*/
        return requestId;
    }

    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    // Called by Chainlink
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        uint256 normalizedRandomNumber = _randomWords[0] %
            s_requests[_requestId].size;

        uint256 raffleId = s_requests[_requestId].id;
        RaffleStruct storage raffle = raffles[raffleId];
        raffle.status = STATUS.CLOSING_REQUESTED;

        // SCENARIO 1
        if (raffle.totalEntriesCap == raffle.entriesLength) {
            emit RandomNumberCreated(
                raffleId,
                _randomWords[0],
                normalizedRandomNumber
            );
            transferFunds(raffleId, normalizedRandomNumber);
        }
        // SCENARIOS 2 AND 3
        else closeRaffleAndRefund(raffleId, normalizedRandomNumber);
    }

    //////////////////////////////////////////////

    /// @dev callable by players. Depending on the number of entries assigned to the price structure the player buys (_id parameter)
    /// one or more entries will be assigned to the player.
    /// Also it is checked the maximum number of entries per user is not reached
    /// As the method is payable, in msg.value there will be the amount paid by the user
    /// @notice If the operator set requiredNFTs when creating the raffle, only the owners of nft on that collection can make a call to this method. This will be
    /// used for special raffles
    /// @param _raffleId: id of the raffle
    /// @param _collection: collection of the tokenId used. Not used if there is no required nft on the raffle
    /// @param _tokenIdUsed: id of the token used in private raffles (to avoid abuse can not be reused on the same raffle)
    function buyEntry(
        uint256 _raffleId,
        address _collection,
        uint256 _tokenIdUsed
    ) external payable nonReentrant {
        RaffleStruct storage raffle = raffles[_raffleId];
        uint256 collectionWLLength = raffle.collectionWhitelist.length;

        require(raffle.price == msg.value, "Price not reached");
        require(
            raffle.entryType == ENTRY_TYPE.MIXED ||
                raffle.entryType == ENTRY_TYPE.ONLY_DIRECTLY,
            "Entry type not allowed"
        );
        require(
            blackListManager.isBlackListed(msg.sender) == false,
            "Blacklisted!"
        );
        // if the raffle requires an nft
        if (collectionWLLength > 0) {
            bool hasRequiredCollection = false;
            for (uint256 i = 0; i < collectionWLLength; i++) {
                if (raffle.collectionWhitelist[i] == _collection) {
                    hasRequiredCollection = true;
                    break;
                }
            }
            require(
                hasRequiredCollection == true,
                "Not in required collection"
            );
            IERC721 requiredNFT = IERC721(_collection);
            require(
                requiredNFT.ownerOf(_tokenIdUsed) == msg.sender,
                "Not the owner of tokenId"
            );
            bytes32 hashRequiredNFT = keccak256(
                abi.encode(_collection, _raffleId, _tokenIdUsed)
            );
            // check the tokenId has not been using yet in the raffle, to avoid abuse
            if (requiredNFTWallets[hashRequiredNFT] == address(0)) {
                requiredNFTWallets[hashRequiredNFT] = msg.sender;
            } else
                require(
                    requiredNFTWallets[hashRequiredNFT] == msg.sender,
                    "tokenId used"
                );
        }

        require(msg.sender != address(0), "msg.sender is null"); // 37
        require(raffle.status == STATUS.ACCEPTED, "Raffle is not in accepted"); // 1808

        require(
            (raffle.totalEntriesCap == 0 ||
                (raffle.entriesLength + 1 <= raffle.totalEntriesCap)),
            "Total Cap Entries reached"
        );

        bytes32 hash = keccak256(abi.encode(msg.sender, _raffleId));
        // check there are enough entries left for this particular user
        require(claimsData[hash] == false, "Bought too many entries");

        EntriesBought memory entryBought = EntriesBought({
            player: msg.sender,
            currentEntriesLength: raffle.entriesLength + 1
        });
        entriesList[_raffleId].push(entryBought);

        raffle.amountRaised += uint128(msg.value);
        // update the field entriesLength, used in frontend to avoid making extra calls
        raffle.entriesLength = raffle.entriesLength + 1;
        // the player already participated on the H2H raffle
        claimsData[hash] = true;

        emit EntrySold(_raffleId, msg.sender, raffle.entriesLength, 0);
    }

    // helper method to get the winner address of a raffle
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber Generated by chainlink
    /// @return the wallet that won the raffle
    /// @dev Uses a binary search on the sorted array to retreive the winner
    /// but if the winner candidate is blacklisted, loop through the left looking for
    /// a candidate not blacklisted
    function getWinnerAddressFromRandom(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) public view returns (address) {
        uint256 position = findUpperBound(
            entriesList[_raffleId],
            _normalizedRandomNumber
        );

        address candidate = entriesList[_raffleId][position].player;
        // general case
        if (candidate != address(0)) return candidate;
        // special case. The user is blacklisted, so try next on the left until find a non-blacklisted
        else {
            bool ended = false;
            uint256 i = position;
            while (
                ended == false && entriesList[_raffleId][i].player == address(0)
            ) {
                if (i == 0) i = entriesList[_raffleId].length - 1;
                else i = i - 1;
                // we came to the beginning without finding a non blacklisted player
                if (i == position) ended == true;
            }
            require(!ended, "All users blacklisted");
            return entriesList[_raffleId][i].player;
        }
    }

    /// @param array sorted array of EntriesBought. CurrentEntriesLength is the numeric field used to sort
    /// @param element uint256 to find. Goes from 1 to entriesLength
    /// @dev based on openzeppelin code (v4.0), modified to use an array of EntriesBought
    /// Searches a sorted array and returns the first index that contains a value greater or equal to element.
    /// If no such index exists (i.e. all values in the array are strictly less than element), the array length is returned. Time complexity O(log n).
    /// array is expected to be sorted in ascending order, and to contain no repeated elements.
    /// https://docs.openzeppelin.com/contracts/3.x/api/utils#Arrays-findUpperBound-uint256---uint256-
    function findUpperBound(EntriesBought[] memory array, uint256 element)
        internal
        pure
        returns (uint256)
    {
        if (array.length == 0) {
            return 0;
        }

        uint256 low = 0;
        uint256 high = array.length;

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds down (it does integer division with truncation).
            if (array[mid].currentEntriesLength > element) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        // At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
        if (low > 0 && array[low - 1].currentEntriesLength == element) {
            return low - 1;
        } else {
            return low;
        }
    }

    // The operator can call this method once they receive the event "RandomNumberCreated"
    // triggered by the VRF v2 consumer contract (RandomNumber.sol)
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber index of the array that contains the winner of the raffle. Generated by chainlink
    /// @notice it is the method that sets the winner and transfers funds
    /// @dev called by Chainlink callback
    function transferFunds(uint256 _raffleId, uint256 _normalizedRandomNumber)
        internal
        nonReentrant
    {
        RaffleStruct storage raffle = raffles[_raffleId];
        // Only when the raffle has been asked to be closed and the platform
        require(
            raffle.status == STATUS.EARLY_CASHOUT ||
                raffle.status == STATUS.CLOSING_REQUESTED,
            "Raffle in wrong status"
        );

        raffle.randomNumber = uint48(_normalizedRandomNumber);
        raffle.winner = getWinnerAddressFromRandom(
            _raffleId,
            _normalizedRandomNumber
        );
        raffle.status = STATUS.ENDED;

        (bool sentPrize, ) = raffle.winner.call{value: raffle.amountOfETH}("");
        require(sentPrize, "Failed to send Ether");

        // The amount for the platform is not a percentage but raised - prize
        uint256 amountForPlatform = (raffle.amountRaised - raffle.amountOfETH);
        // transfer the amount to the platform
        (bool sent2, ) = destinationWallet.call{value: amountForPlatform}("");
        require(sent2, "Failed send Eth to MW");
        emit FeeTransferredToPlatform(_raffleId, amountForPlatform);

        emit RaffleEnded(
            _raffleId,
            raffle.winner,
            raffle.amountRaised,
            _normalizedRandomNumber
        );
    }

    /// @param _raffleId Id of the raffle
    /// @notice the operator finish the raffle, if the desired funds has been reached
    /// @dev it triggers Chainlink VRF1 consumer, and generates a random number that is normalized and checked that corresponds to a MW player
    function setWinner(uint256 _raffleId)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        RaffleStruct storage raffle = raffles[_raffleId];

        // if there are no participants, when calculating the winner will trigger a division by zero
        require(raffle.entriesLength != 0, "No participants in the raffle");

        // Check if the raffle is already accepted or is called again because early cashout failed
        require(raffle.status == STATUS.ACCEPTED, "Raffle in wrong status");
        raffle.status = STATUS.CLOSING_REQUESTED;

        // this call trigers the VRF v2 process from Chainlink
        getRandomNumber(_raffleId, raffle.entriesLength);

        emit SetWinnerTriggered(_raffleId, raffle.amountRaised);
    }

    /// @param _newAddress new address of the platform
    /// @dev Change the wallet of the platform. The one that will receive the platform fee when the raffle is closed.
    /// Only the admin can change this
    function setDestinationAddress(address payable _newAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        destinationWallet = _newAddress;
    }

    /// @param _raffleId Id of the raffle
    /// @return array of entries bougth of that particular raffle
    function getEntriesBought(uint256 _raffleId)
        external
        view
        returns (EntriesBought[] memory)
    {
        return entriesList[_raffleId];
    }

    /// @dev if a player has been blacklisted, their entries must be void
    /// this has a cost in gas, but this makes cheaper in gas the callback from chainlink
    /// This method has to be called for every raffle of the blacklisted player
    /// @param _raffleId Id of the raffle
    /// @param entriesToCancel array that contains the index of the entries to cancel. 0 based
    /// @param _player blacklisted player who owns the entry to be voided
    function cancelEntry(
        uint256 _raffleId,
        uint256[] calldata entriesToCancel,
        address _player
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 totalEntriesBoughtCancelled = 0;
        for (uint256 i = 0; i < entriesToCancel.length; i++) {
            EntriesBought storage entry = entriesList[_raffleId][
                entriesToCancel[i]
            ];

            require(entry.player == _player, "Entry did not belong to player");

            entry.player = address(0);

            uint256 previousTotalEntriesLength;
            if (entriesToCancel[i] == 0) previousTotalEntriesLength = 0;
            else
                previousTotalEntriesLength = entriesList[_raffleId][
                    entriesToCancel[i] - 1
                ].currentEntriesLength;
            totalEntriesBoughtCancelled +=
                entry.currentEntriesLength -
                previousTotalEntriesLength;
        }
        emit EntryCancelled(_raffleId, totalEntriesBoughtCancelled, _player);
    }

    // When the contract is replaced, or if there was sent too much ETH to the contract for the
    // case of SCENARIO 2, calling this method will sent some ETH from the contract to the
    // destination wallet
    function withdraw(uint256 amount)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        (bool sent, ) = destinationWallet.call{value: amount}("");
        require(sent, "Fail send Eth to MW");
    }

    /// @notice Creates a H2H (with multiple players, not only 2)
    /// Each player funds the competition by buying entries. So no need to
    /// stake on the raffle like in previous versions
    /// @dev unfulfilledAmount is the total amount paid to the first buyer in
    /// SCENARIO 2. Not an extra fee to add to the amount paid.
    /// @param _amountOfETH the prize in weis the winner will get if SCENARIO 1 occurs
    /// @param _unfulfilledAmount paid price + extra the first player will get in SCENARIO 2
    /// @param _price Amount in weis a player must enter to participate in the H2H competition
    function createH2HRaffle(
        uint128 _amountOfETH,
        uint128 _unfulfilledAmount,
        uint128 _price,
        address[] calldata _collectionWhitelist,
        ENTRY_TYPE _entryType,
        uint48 _totalEntriesCap
    ) external onlyRole(OPERATOR_ROLE) returns (uint256) {
        unchecked {
            require(_amountOfETH != 0, "Prize is 0");

            RaffleStruct memory raffle = RaffleStruct({
                status: STATUS.ACCEPTED, // no stake, so it is automatically in accepted
                amountOfETH: _amountOfETH,
                winner: address(0),
                randomNumber: 0,
                amountRaised: 0,
                entriesLength: 0,
                cancellingDate: 0,
                collectionWhitelist: _collectionWhitelist,
                entryType: _entryType,
                totalEntriesCap: _totalEntriesCap,
                unfulfilledAmount: _unfulfilledAmount,
                price: _price
            });

            raffles.push(raffle);

            uint256 raffleId = raffles.length - 1;

            emit RaffleCreated(raffleId, _amountOfETH);

            return raffleId;
        }
    }

    /// @dev This method manages SCENARIO 2 and SCENARIO 3
    /// So when a raffle cannot be fulfilled because either there are no purchases
    /// or there are only a few players.
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber index of the array that contains the winner of the raffle. Generated by chainlink
    function closeRaffleAndRefund(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) internal {
        RaffleStruct storage raffle = raffles[_raffleId];
        require(raffle.status == STATUS.CLOSING_REQUESTED, "Wrong status");
        uint256 amountOfEntries = raffle.entriesLength;

        // SCENARIO 2
        // There are boughts, but not enough to reach the required amount
        // The first player to bought, gets an extra amount to incentivate players to participate
        // The status of the competition is not cancelled but UNFULFILLED, and a new event is sent
        if (amountOfEntries != 0) {
            uint256 amountToRefundPerPlayer = raffle.price;
            require(
                address(this).balance >
                    raffle.unfulfilledAmount +
                        (amountToRefundPerPlayer * (amountOfEntries - 1)),
                "Not enough balance"
            );

            raffle.status = STATUS.UNFULFILLED;
            raffle.winner = entriesList[_raffleId][0].player;
            raffle.randomNumber = uint48(_normalizedRandomNumber);
            emit RaffleUnfulfilled(
                _raffleId,
                raffle.winner,
                raffle.unfulfilledAmount,
                _normalizedRandomNumber,
                raffle.amountRaised
            );

            for (uint256 i; i < amountOfEntries; ++i) {
                if (i == 0) // first player has special bonus
                {
                    (bool sentFundsBack, ) = entriesList[_raffleId][i]
                        .player
                        .call{value: raffle.unfulfilledAmount}("");
                    require(sentFundsBack, "Failed to send Ether 1");
                } else {
                    (bool sentFundsBack, ) = entriesList[_raffleId][i]
                        .player
                        .call{value: amountToRefundPerPlayer}("");
                    require(sentFundsBack, "Failed to send Ether");
                }
            }
        }
        // SCENARIO 3.
        // Nobody boughts, no need to refund anything. Just set status to cancelled and send event
        // Theoretically this branch should never be reached, as there are checks done both back
        // and in method SetWinner to avoid calling chainlink if there are 0 entries bought
        else {
            raffle.status = STATUS.CANCELLED;
            raffle.cancellingDate = uint48(block.timestamp);
            emit RaffleCancelled(_raffleId, raffle.amountRaised);
        }
    }

    /// @notice Will receive any eth sent to the contract. We will use it to send some ETH
    /// for the case of the extra amount paid to first player to buy in SCENARIO 2
    receive() external payable {}

    /// @dev lets the operator to change the blacklist contract used. For example in case
    /// of updating the blacklistManager contract
    /// @param _blacklistManager address of the new BlacklistManager contract
    function changeBlackList(address _blacklistManager)
        external
        onlyRole(OPERATOR_ROLE)
    {
        blackListManager = BlackListManager(_blacklistManager);
    }

    /// @dev cancels a raffle, and in the case of having some entries bought, it refunds them
    /// Avoid cancelling two times the same raffle
    function cancelRaffle(uint256 _raffleId) external onlyRole(OPERATOR_ROLE) {
        RaffleStruct storage raffle = raffles[_raffleId];
        require(raffle.status != STATUS.CANCELLED, "Already canceled");
        uint256 amountOfEntries = raffle.entriesLength;

        // if there are already players
        if (amountOfEntries > 0) {
            // send funds back to existing players
            for (uint256 i; i < amountOfEntries; ++i) {
                (bool sentFundsBack, ) = entriesList[_raffleId][i].player.call{
                    value: raffle.price
                }("");
                require(sentFundsBack, "Failed to refund");
            }
        }
        raffle.status = STATUS.CANCELLED;
        raffle.cancellingDate = uint48(block.timestamp);
        emit RaffleCancelled(_raffleId, raffle.amountRaised);
    }
}
