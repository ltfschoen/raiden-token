pragma solidity ^0.4.11;

import './safe_math.sol';
import './utils.sol';
import './mint.sol';

contract Auction {
    address public owner;
    Mint mint;
    uint factor;
    uint const;
    uint public startTimestamp;
    uint public endTimestamp;
    uint received_value = 0;
    uint total_issuance = 0;
    uint issued_value = 0;
    mapping(address => uint256) public bidders;

    enum Stages {
        AuctionDeployed,
        AuctionSetUp,
        AuctionStarted,
        AuctionEnded,
        AuctionSettled
    }

    Stages public stage;

    modifier isOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier isValidPayload() {
        require(msg.data.length == 4 || msg.data.length == 36);
        _;
    }

    modifier atStage(Stages _stage) {
        require(stage == _stage);
        _;
    }

    event LogAuctionEnded(uint price, uint issuance);

    function Auction(uint _factor, uint _const) {
        factor = _factor;
        const = _const;
        stage = Stages.AuctionDeployed;
        owner = msg.sender;
    }

    // Fallback function
    function()
        payable
    {
        order();
    }

    function setup(address _mint)
        public
        isOwner
        atStage(Stages.AuctionDeployed)
    {
        require(_mint != 0x0);
        mint = Mint(_mint);
        stage = Stages.AuctionSetUp;
    }

    // TODO determine how last_call should work
    function startAuction(bool last_call)
        public
        isOwner
        atStage(Stages.AuctionSetUp)
    {
        if(last_call) {
            stage = Stages.AuctionStarted;
            startTimestamp = now;
        }
    }

    function order()
        public
        payable
        isValidPayload
        atStage(Stages.AuctionStarted)
    {
        uint accepted_value = SafeMath.min256(missingReserveToEndAuction(), msg.value);
        if (accepted_value < msg.value) {
            msg.sender.transfer(SafeMath.sub(
                msg.value,
                accepted_value));
            finalizeAuction();
        }

        bidders[msg.sender] = SafeMath.add(bidders[msg.sender], accepted_value);
    }

    function claimTokens(address[] recipients)
        public
        atStage(Stages.AuctionEnded)
    {
        // called multiple times (gas limit!) until all bidders got their tokens
        for(uint i = 0; i < recipients.length; i++) {
            uint num = bidders[recipients[i]] * total_issuance / received_value;
            issued_value += bidders[recipients[i]];
            bidders[recipients[i]] = 0;
            mint.issueFromAuction(recipients[i], num);
        }

        if (issued_value == received_value) {
            stage = Stages.AuctionSettled;
            mint.startTrading();
        }
    }

    function price()
        public
        constant
        returns(uint)
    {
        uint elapsed = SafeMath.sub(now, startTimestamp);
        return SafeMath.add(factor / elapsed, const);
    }

    // TODO do we need this?
    function isactive()
        public
        constant
    {
        // true if this.price > mint.curvePriceAtReserve(this.balance)
        // modelled as atStage(Stages.AuctionStarted)
    }

    function missingReserveToEndAuction()
        public
        constant
        atStage(Stages.AuctionStarted)
        returns (uint)
    {
        // Calculate reserve at the current auction price
        uint auction_price = price();
        auction_price -= mint.ownerFraction(auction_price);
        uint simulated_reserve = mint.curveReserveAtPrice(auction_price);

        // Calculate current reserve (auction + preallocated mint reserve)
        uint current_reserve = SafeMath.add(this.balance, mint.balance);

        // Auction ends when simulated auction reserve is < the current reserve
        if(simulated_reserve < current_reserve) {
            return 0;
        }
        return SafeMath.sub(simulated_reserve, current_reserve);
    }

    // the mktcap if the auction would end at the current price
    function maxMarketCap()
        public
        constant
        returns (uint)
    {
        uint vsupply = mint.curveSupplyAtPrice(mint.ask());
        return SafeMath.mul(mint.ask(), vsupply);
    }

    // the valuation if the auction would end at the current price
    function maxValuation()
        public
        constant
        returns (uint)
    {
        // FIXME
        // TODO check beneficiary fraction
        // return maxMarketCap() * beneficiary.get_fraction();

        return mint.ownerFraction(maxMarketCap());
    }

    function finalizeAuction()
        private
        atStage(Stages.AuctionStarted)
    {
        // TODO do we need this? - private, called only from order()
        uint mint_ask = mint.curvePriceAtReserve(this.balance);
        mint_ask -= mint.ownerFraction(mint_ask);
        require(price() <= mint_ask);

        // memorize received funds
        received_value = this.balance;
        total_issuance = SafeMath.sub(
            mint.curveSupplyAtReserve(SafeMath.add(
                received_value,
                mint.balance)),
            mint.totalSupply()
        );

        // send funds to mint
        mint.fundsFromAuction.value(this.balance);

        stage = Stages.AuctionEnded;
        endTimestamp = now;
        LogAuctionEnded(received_value, total_issuance);
    }
}