pragma solidity ^0.4.11;

import './safe_math.sol';
import './utils.sol';
import './token.sol';

/// @title Dutch auction contract - distribution of tokens using an auction.
/// @author [..] credits to Stefan George - <stefan.george@consensys.net>
contract DutchAuction {
    /*
     *  Storage
     */
    RaidenToken public token;
    address public owner;

    // Price function parameters
    uint public price_factor;
    uint public price_const;

    // For calculating elapsed time for price
    uint public start_time;
    uint public end_time;
    uint public start_block;

    // Keep track of funds claimed after auction has ended
    uint public funds_claimed;

    // Total number of tokens that will be auctioned
    uint public tokens_auctioned;

    // Wei per TKN (Tei * multiplier)
    uint public final_price;

    // Owner issuance fraction = % of tokens assigned to owner from the total auction supply
    uint public owner_fr;
    uint public owner_fr_dec;

    mapping (address => uint) public bids;
    Stages public stage;

    // Terminology:
    // 1 token unit = Tei
    // 1 token = TKN = Tei * multiplier
    // multiplier set from token's number of decimals (i.e. 10**decimals)
    uint multiplier;

    /*
     *  Enums
     */
    enum Stages {
        AuctionDeployed,
        AuctionSetUp,
        AuctionStarted,
        AuctionEnded,
        TokensDistributed,
        TradingStarted
    }

    /*
     *  Modifiers
     */
    modifier atStage(Stages _stage) {
        require(stage == _stage);
        _;
    }

    modifier isOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier isValidPayload() {
        require(msg.data.length == 4 || msg.data.length == 36);
        _;
    }

    /*
     *  Events
     */

    event Deployed(address indexed auction, uint indexed price_factor, uint indexed price_const, uint owner_fr, uint owner_fr_dec);
    event Setup();
    event SettingsChanged(uint indexed price_factor, uint indexed price_const, uint owner_fr, uint owner_fr_dec);
    event AuctionStarted(uint indexed start_time, uint indexed block_number);
    event BidSubmission(address indexed sender, uint amount, uint returned_amount, uint indexed missing_reserve);
    event ClaimedTokens(address indexed recipient, uint sent_amount, uint num, uint recipient_num, uint owner_num);
    event AuctionEnded(uint indexed final_price);
    event TokensDistributed();
    event TradingStarted();

    /*
     *  Public functions
     */

    /// @dev Contract constructor function sets owner.
    /// @param _price_factor Auction price factor.
    /// @param _price_const Auction price divisor constant.
    /// @param _owner_fr Auction owner issuance fraction (e.g. 15 for 0.15).
    /// @param _owner_fr_dec Auction owner issuance fraction decimals (e.g. 2 for 0.15).
    function DutchAuction(
        uint _price_factor,
        uint _price_const,
        uint _owner_fr,
        uint _owner_fr_dec)
        public
    {
        require(_price_factor != 0);
        require(_price_const != 0);
        require(_owner_fr != 0);
        require(_owner_fr_dec != 0);

        // Example (15, 2) means 15%, we cannot have 1500%
        require(Utils.num_digits(owner_fr) <= owner_fr_dec);

        owner = msg.sender;
        price_factor = _price_factor;
        price_const = _price_const;
        owner_fr = _owner_fr;
        owner_fr_dec = _owner_fr_dec;

        stage = Stages.AuctionDeployed;
        Deployed(this, price_factor, price_const, owner_fr, owner_fr_dec);
    }

    /// @dev Setup function sets external contracts' addresses.
    /// @param _token Token address.
    function setup(address _token)
        public
        isOwner
        atStage(Stages.AuctionDeployed)
    {
        require(_token != 0x0);
        token = RaidenToken(_token);

        // Get number of tokens to be auctioned from token auction balance
        tokens_auctioned = token.balanceOf(this);

        // Set number of tokens multiplier from token decimals
        multiplier = 10**uint(token.decimals());

        stage = Stages.AuctionSetUp;
        Setup();
    }

    /// @dev Changes auction start price factor before auction is started.
    /// @param _price_factor Updated price factor.
    /// @param _price_const Updated price divisor constant.
    /// @param _owner_fr Updated owner issuance fraction (e.g. 15 for 0.15).
    /// @param _owner_fr_dec Updated owner issuance fraction decimals (e.g. 2 for 0.15).
    function changeSettings(
        uint _price_factor,
        uint _price_const,
        uint _owner_fr,
        uint _owner_fr_dec)
        public
        atStage(Stages.AuctionSetUp)
    {
        require(_price_factor != 0);
        require(_price_const != 0);
        require(_owner_fr != 0);
        require(_owner_fr_dec != 0);

        // Example (10, 2) means 10%, we cannot have 1000%
        require(Utils.num_digits(owner_fr) <= owner_fr_dec);

        price_factor = _price_factor;
        price_const = _price_const;
        owner_fr = _owner_fr;
        owner_fr_dec = _owner_fr_dec;
        SettingsChanged(price_factor, price_const, owner_fr, owner_fr_dec);
    }

    /// @dev Starts auction and sets start_time.
    function startAuction()
        public
        isOwner
        atStage(Stages.AuctionSetUp)
    {
        stage = Stages.AuctionStarted;
        start_time = now;
        start_block = block.number;
        AuctionStarted(start_time, start_block);
    }

    /// --------------------------------- Auction Functions -------------------------------------------

    /// @dev Allows to send a bid to the auction.
    function bid()
        public
        payable
        atStage(Stages.AuctionStarted)
    {
        bid(msg.sender);
    }

    /// @dev Allows to send a bid to the auction.
    /// @param receiver Bidder account address.
    function bid(address receiver)
        public
        payable
        isValidPayload
        atStage(Stages.AuctionStarted)
    {
        require(receiver != 0x0);

        uint amount = msg.value;

        // Missing reserve without the current bid amount
        uint maxWei = missingReserveToEndAuction(this.balance - amount);

        // Only invest maximum possible amount.
        if (amount > maxWei) {
            amount = maxWei;
            // Send change back to receiver address.
            receiver.transfer(msg.value - amount);
        }
        bids[receiver] += amount;
        BidSubmission(receiver, amount, msg.value - amount, maxWei);

        if (maxWei == amount) {
            // When maxWei is equal to the big amount the auction is ended and finalizeAuction is triggered.
            finalizeAuction();
        }
    }

    /// @dev Claims tokens for bidder after auction. To be used if tokens can be claimed by bidders, individually.
    function claimTokens()
        public
        atStage(Stages.AuctionEnded)
    {
        claimTokens(msg.sender);
    }

    /// @dev Claims tokens for bidder after auction.
    /// @param receiver Tokens will be assigned to this address if set.
    function claimTokens(address receiver)
        public
        isValidPayload
        atStage(Stages.AuctionEnded)
    {
        require(receiver != 0x0);
        require(bids[receiver] > 0);

        // Number of Tei = bidded_wei / wei_per_TKN * multiplier
        uint num = bids[receiver] * multiplier / final_price;
        uint owner_num = ownerFraction(num);
        uint recipient_num = num - owner_num;
        funds_claimed += bids[receiver];

        ClaimedTokens(receiver, bids[receiver], num, recipient_num, owner_num);

        bids[receiver] = 0;

        token.transfer(owner, owner_num);
        token.transfer(receiver, recipient_num);

        if (funds_claimed == this.balance) {
            stage = Stages.TokensDistributed;
            TokensDistributed();
            transferReserveToToken();
        }
    }

    /// @dev Get the owner issuance fraction from the provided supply / number of tokens.
    /// @param supply Number of tokens.
    /// @return Returns number of tokens issued for the auction owner.
    function ownerFraction(uint supply)
        public
        constant
        returns (uint)
    {
        return SafeMath.mul(supply, owner_fr) / 10**owner_fr_dec;
    }

    /*
     *  Private functions
     */

    /// @dev Finalize auction and set the final token price.
    function finalizeAuction()
        private
        atStage(Stages.AuctionStarted)
    {
        final_price = calcTokenPrice();
        end_time = now;
        stage = Stages.AuctionEnded;
        AuctionEnded(final_price);
    }

    /// @dev Transfer auction balance to the token.
    function transferReserveToToken()
        private
        atStage(Stages.TokensDistributed)
    {
        token.receiveReserve.value(this.balance)();
        stage = Stages.TradingStarted;
        TradingStarted();
    }

    /// @dev Calculates the token price at the current timestamp during the auction.
    /// @return Returns the token price - Wei per Tei.
    function calcTokenPrice()
        constant
        private
        atStage(Stages.AuctionStarted)
        returns (uint)
    {
        uint elapsed = now - start_time;
        return price_factor * multiplier / (elapsed + price_const) + 1;
    }

    /// --------------------------------- Price Functions -------------------------------------------

    /// @dev Calculates current token price.
    /// @return Returns num Wei per TKN (Tei * multiplier).
    function price()
        public
        constant
        returns (uint)
    {
        if (stage == Stages.AuctionEnded) {
            return final_price;
        }
        return calcTokenPrice();
    }

    /// @dev Calculates the simulated reserve at the current price.
    /// @return Returns the simulated reserve amount.
    function reserveAtPrice()
        constant
        public
        returns (uint)
    {
        return tokens_auctioned * price() / multiplier;
    }

    /// @dev The missing reserve amount necessary to end the auction at the current price.
    /// @return Returns the missing reserve amount.
    function missingReserveToEndAuction()
        constant
        public
        returns (uint)
    {
        return missingReserveToEndAuction(this.balance);
    }

    /// @dev The missing reserve amount necessary to end the auction at the current price, for a provided reserve/balance.
    /// @param reserve Reserve amount - might be current balance or current balance without current bid value for bid().
    /// @return Returns the missing reserve amount.
    function missingReserveToEndAuction(uint reserve)
        constant
        public
        returns (uint)
    {
        return SafeMath.max256(0, reserveAtPrice() - reserve);
    }
}
