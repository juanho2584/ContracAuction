// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Auction {
    address public owner;
    uint public deadline;
    uint public commissionPercent = 2;
    uint public timeExtension = 10 minutes;
    bool public ended;

    struct Bid {
        address bidder;
        uint amount;
    }

    Bid[] public bidHistory;
    Bid public highestBid;

    // mappings
    mapping(address => uint) public accumulatedBids;
    mapping(address => uint[]) public userBidHistory;
    mapping(address => uint) public refunds;

   
    // events
    event NewBid(address indexed bidder, uint amount);
    event AuctionEnded(address winner, uint winningAmount);


    // modifiers
    modifier onlyBeforeEnd() {
        require(block.timestamp < deadline, "The auction has ended.");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can perform this action.");
        _;
    }

    // construct
    constructor(uint _durationSeconds) {
        owner = msg.sender;
        deadline = block.timestamp + _durationSeconds;
    }

    //funtions
    function placeBid() external payable onlyBeforeEnd {
        require(msg.value > 0, "You must send a value greater than 0.");

        accumulatedBids[msg.sender] += msg.value;
        userBidHistory[msg.sender].push(msg.value);

        uint totalBid = accumulatedBids[msg.sender];
        uint requiredAmount = highestBid.amount + (highestBid.amount * 5) / 100;

        require(totalBid >= requiredAmount, "Your total bid must exceed the highest bid by at least 5%.");

        // Update highest bid
        highestBid = Bid(msg.sender, totalBid);
        bidHistory.push(highestBid);

        // Extend auction if less than 10 minutes remain
        if (deadline - block.timestamp <= 10 minutes) {
            deadline += timeExtension;
        }

        emit NewBid(msg.sender, totalBid);
    }

    function endAuction() external onlyOwner {
        require(block.timestamp >= deadline, "The auction has not ended yet.");
        require(!ended, "Already ended.");
        ended = true;

        uint commission = (highestBid.amount * commissionPercent) / 100;
        uint amountForOwner = highestBid.amount - commission;

        payable(owner).transfer(amountForOwner);

        emit AuctionEnded(highestBid.bidder, highestBid.amount);
    }

    function withdrawDeposit() external {
        require(ended, "The auction has not ended.");
        require(msg.sender != highestBid.bidder, "The winner cannot withdraw.");

        uint amount = accumulatedBids[msg.sender];
        require(amount > 0, "No deposit available.");

        accumulatedBids[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
    }

    function getWinner() external view returns (address, uint) {
        return (highestBid.bidder, highestBid.amount);
    }

    function getBidHistory() external view returns (Bid[] memory) {
        return bidHistory;
    }

    function timeRemaining() external view returns (uint) {
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function bidsOf(address user) external view returns (uint[] memory) {
        return userBidHistory[user];
    }
}
