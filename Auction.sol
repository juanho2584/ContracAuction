// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Auction Contract
 * @notice Implements a transparent auction system with automatic refunds for non-winning bidders
 * @dev Features include:
 * - Time extensions on late bids
 * - Minimum 5% bid increments
 * - 2% commission on bids
 * - Secure withdrawal patterns
 * - Automatic refunds for non-winning bidders
 */
contract Auction {
    /// @dev The address of the contract owner
    address private owner;

    /// @dev Timestamp when auction bidding ends
    uint private deadline;

    /// @dev Fixed commission percentage taken on bids
    /// @notice Value is 2 representing 2% commission
    /// @custom:immutable Set at compile time, cannot be changed
    uint private constant commissionPercent = 2; // 2% commission

    /// @dev Duration added to deadline when last-minute bids occur
    /// @notice Set to 10 minutes in seconds (600)
    /// @custom:invariant Always extends auction by this exact duration
    uint private constant timeExtension = 10 minutes;

    /// @dev Flag indicating auction completion status
    /// @notice Once true, prevents further state changes
    /// @custom:transition Only changes from false → true once
    bool private ended;

    /**
     * @title Bid Structure
     * @notice Represents a single bid in the auction system
     * @dev Contains bidder address and bid amount
     */
    struct Bid {
        /// @notice Address of the bidder who placed this bid
        address bidder;
        
        /// @notice Amount of ETH bid (in wei)
        /// @dev Must be higher than previous bids to be valid
        uint amount;
    }

    /// @dev Complete history of all valid bids received
    /// @notice Array stores Bid structs in chronological order
    Bid[] private bidHistory;

    /// @dev Current highest valid bid in the auction
    /// @custom:invariant amount must be >= reserve price
    Bid private highestBid;

    /// @dev Tracks the total accumulated bid amount per address
    mapping(address => uint) private accumulatedBids;
    
    /// @dev Stores the history of all bid amounts per address
    mapping(address => uint[]) private userBidHistory;
    
    /// @dev Tracks refundable amounts (98% of bids) per address
    mapping(address => uint) public pendingWithdrawals;

    /**
     * @dev Emitted when a new bid is placed
     * @param bidder The address of the bidder (indexed for filtering)
     * @param amount The amount of ETH bid (in wei)
     */
    event NewBid(address indexed bidder, uint amount);

    /**
     * @dev Emitted when a bidder places a bid that creates excess funds
     * @param bidder Address of the bidder with excess funds (indexed)
     * @param amount Amount of excess ETH available for withdrawal
     */
    event ExcessFundsAvailable(address indexed bidder, uint amount);

    /**
     * @dev Emitted when the auction concludes
     * @param winner The address of the winning bidder
     * @param winningAmount The final winning bid amount (in wei)
     */
    event AuctionEnded(address winner, uint winningAmount);

    /**
     * @dev Emitted when a bidder withdraws excess funds
     * @param bidder Address receiving the partial refund (indexed)
     * @param amount Amount refunded
     */
    event PartialRefund(address indexed bidder, uint amount);

    /**
     * @dev Emitted when users withdraw their deposits
     * @param user The address withdrawing funds (indexed)
     * @param refundAmount The amount returned to user (98%)
     * @param fee The fee retained by contract (2%)
     */
    event DepositWithdrawn(address indexed user, uint refundAmount, uint fee);

    /**
     * @dev Emitted when contract funds are withdrawn under emergency
     * @param receiver The destination address for emergency funds
     * @param amount The amount of ETH withdrawn in wei
     */
    event EmergencyWithdraw(address indexed receiver, uint amount);

    /**
     * @dev Emitted when non-winning bids are automatically refunded
     * @param bidder The address receiving the refund (indexed)
     * @param refundAmount The amount returned to bidder (98%)
     * @param fee The commission retained by contract (2%)
     */
    event DepositRefunded(address indexed bidder, uint refundAmount, uint fee);

    /**
     * @dev Modifier to check if the auction is still active
     * @notice Reverts if the current time is past the auction deadline
     * @custom:reverts AuctionEnded if auction deadline has passed
     */
    modifier onlyBeforeEnd() {
        require(block.timestamp < deadline, "Auction has ended");
        _;
    }

    /**
     * @dev Modifier to restrict access to the contract owner only
     * @notice Reverts if caller is not the current contract owner
     * @custom:reverts NotOwner if called by non-owner
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /**
     * @notice Initializes the auction contract
     * @dev Sets the owner and calculates the auction deadline
     * @param _durationSeconds The duration of the auction in seconds from deployment
     */
    constructor(uint _durationSeconds) {
        owner = msg.sender;
        deadline = block.timestamp + _durationSeconds;
    }

    /**
     * @notice Places a new bid in the auction
     * @dev Requirements:
     *      - Auction must still be active
     *      - Bid value must be > 0
     *      - For non-first bids: must be 5% higher than current highest
     *      - Bidder cannot be current highest bidder
     * @dev Effects:
     *      - Updates accumulated bids for sender
     *      - May update highest bid
     *      - May extend auction deadline
     * @custom:reverts BidTooLow if bid doesn't meet minimum requirements
     * @custom:reverts AuctionEnded if auction deadline has passed
     */
    function placeBid() external payable onlyBeforeEnd {
        require(msg.value > 0, "Bid must be > 0");

        if (highestBid.amount == 0) {
            accumulatedBids[msg.sender] = msg.value;
            userBidHistory[msg.sender].push(msg.value);
            highestBid = Bid(msg.sender, msg.value);
            bidHistory.push(highestBid);
            emit NewBid(msg.sender, msg.value);
            return;
        }

        require(msg.sender != highestBid.bidder, "Already highest bidder");
        uint requiredAmount = highestBid.amount + (highestBid.amount * 5) / 100;
        uint newTotalBid = accumulatedBids[msg.sender] + msg.value;
        require(newTotalBid > requiredAmount, "Bid must be 5% higher");

        uint excess = 0;
        if (accumulatedBids[msg.sender] > requiredAmount) {
            excess = accumulatedBids[msg.sender] - requiredAmount;
        }

        accumulatedBids[msg.sender] = newTotalBid;
        userBidHistory[msg.sender].push(msg.value);

        if (excess > 0) {
            emit ExcessFundsAvailable(msg.sender, excess);
        }

        if (newTotalBid > highestBid.amount) {
            highestBid = Bid(msg.sender, newTotalBid);
            bidHistory.push(highestBid);
            
            if (deadline - block.timestamp <= timeExtension) {
                deadline += timeExtension;
            }
        }

        emit NewBid(msg.sender, newTotalBid);
    }

    /**
     * @notice Finalizes the auction and distributes funds
     * @dev Requirements:
     *      - Only callable by owner
     *      - Auction must be past deadline
     *      - Auction must not have already ended
     *      - At least one valid bid must exist
     * @dev Effects:
     *      - Marks auction as ended
     *      - Transfers winning bid (minus 2%) to owner
     *      - Automatically refunds 98% to non-winning bidders
     * @custom:reverts NotOwner if called by non-owner
     * @custom:reverts AuctionNotEnded if current time < deadline
     * @custom:reverts AuctionAlreadyEnded if auction was already finalized
     * @custom:reverts NoBids if no bids were placed
     */
    function endAuction() external onlyOwner {
        require(block.timestamp >= deadline, "Auction not ended");
        require(!ended, "Auction already ended");
        require(highestBid.amount > 0, "No bids placed");

        ended = true;
        uint commission = (highestBid.amount * commissionPercent) / 100;
        payable(owner).transfer(highestBid.amount - commission);

        emit AuctionEnded(highestBid.bidder, highestBid.amount);

        for (uint i = 0; i < bidHistory.length; i++) {
            address bidder = bidHistory[i].bidder;
            if (bidder != highestBid.bidder && accumulatedBids[bidder] > 0) {
                uint amount = accumulatedBids[bidder];
                uint refundAmount = amount - (amount * commissionPercent) / 100;
                
                accumulatedBids[bidder] = 0;
                payable(bidder).transfer(refundAmount);
                
                emit DepositRefunded(bidder, refundAmount, (amount * commissionPercent) / 100);
            }
        }
    }

    /**
     * @notice Allows bidders to withdraw refundable deposits
     * @dev Requirements:
     *      - Auction must have ended
     *      - Caller must have refundable balance
     * @dev Effects:
     *      - Transfers 98% of caller's total bids
     *      - Resets caller's pending withdrawal balance
     * @return success True if withdrawal was successful
     * @custom:reverts AuctionNotEnded if auction is still active
     * @custom:reverts NoRefund if no refund available
     */
    function claimRefund() external returns (bool success) {
        require(ended, "Auction not ended");
        uint amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No refund available");

        pendingWithdrawals[msg.sender] = 0;
        payable(msg.sender).transfer(amount);

        emit DepositWithdrawn(
            msg.sender,
            amount,
            (amount * commissionPercent) / 98
        );
        
        return true;
    }

    /**
     * @notice Allows withdrawal of excess bid amounts
     * @dev Requirements:
     *      - Auction must be active
     *      - Caller must have excess funds
     *      - Caller must not be current highest bidder
     * @return success True if withdrawal was successful
     * @custom:reverts AuctionEnded if auction has ended
     * @custom:reverts NoExcessFunds if no excess available
     * @custom:reverts CurrentHighestBidder if caller is highest bidder
     */
    function withdrawExcess() external onlyBeforeEnd returns (bool success) {
        uint currentRequired = highestBid.amount + (highestBid.amount * 5) / 100;
        uint excessAmount = accumulatedBids[msg.sender] - currentRequired;
        
        require(excessAmount > 0, "No excess funds available");
        require(msg.sender != highestBid.bidder, "Current highest bidder cannot withdraw");

        accumulatedBids[msg.sender] = currentRequired;
        payable(msg.sender).transfer(excessAmount);

        emit PartialRefund(msg.sender, excessAmount);
        return true;
    }

    /**
     * @notice Emergency withdrawal of contract funds
     * @dev Requirements:
     *      - Only callable by owner
     *      - Auction must have ended
     * @custom:reverts NotOwner if called by non-owner
     * @custom:reverts AuctionNotEnded if auction is still active
     */
    function emergencyWithdraw() external onlyOwner {
        require(ended, "Auction not ended");
        payable(owner).transfer(address(this).balance);
        emit EmergencyWithdraw(owner, address(this).balance);
    }

    // ====================== VIEW FUNCTIONS ====================== //

    /**
     * @notice Returns current highest bid information
     * @return bidder Address of current highest bidder
     * @return amount Amount of current highest bid in wei
     */
    function getHighestBid() external view returns (address bidder, uint amount) {
        return (highestBid.bidder, highestBid.amount);
    }

    /**
     * @notice Returns the complete bid history
     * @return Array of all historical highest bids
     */
    function getBidHistory() external view returns (Bid[] memory) {
        return bidHistory;
    }

    /**
     * @notice Returns remaining auction time
     * @return remainingTime Seconds until auction ends (0 if ended)
     */
    function timeRemaining() external view returns (uint remainingTime) {
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice Returns bid history for specific user
     * @param user Address to query
     * @return userBids Array of bid amounts made by user
     */
    function bidsOf(address user) external view returns (uint[] memory userBids) {
        return userBidHistory[user];
    }

    /**
     * @notice Returns auction deadline timestamp
     * @return auctionDeadline The block timestamp when auction ends
     */
    function getDeadline() external view returns (uint auctionDeadline) {
        return deadline;
    }

    /**
     * @notice Returns contract owner address
     * @return contractOwner The owner address
     */
    function getOwner() external view returns (address contractOwner) {
        return owner;
    }

    /**
     * @notice Checks if auction has ended
     * @return endedStatus True if auction ended, false otherwise
     */
    function isEnded() external view returns (bool endedStatus) {
        return ended;
    }

    /**
     * @notice Returns total bids for a user
     * @param user Address to query
     * @return totalBidAmount Sum of all bids placed by user
     */
    function totalBidOf(address user) external view returns (uint totalBidAmount) {
        return accumulatedBids[user];
    }
}