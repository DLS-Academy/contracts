pragma solidity ^0.4.11;

/*
    Copyright 2017, Jordi Baylina

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/// @title DLTContribution Contract
/// @author Jordi Baylina
/// @dev This contract will be the DLT controller during the contribution period.
///  This contract will determine the rules during this period.
///  Final users will generally not interact directly with this contract. ETH will
///  be sent to the DLT contract. The ETH is sent to this contract and from here,
///  ETH is sent to the contribution walled and DLTs are mined according to the defined
///  rules.


import "./Owned.sol";
import "./MiniMeToken.sol";
import "./SafeMath.sol";
import "./ERC20Token.sol";

contract DLTContribution is Owned, TokenController {
    using SafeMath for uint256;

    uint256 constant public failSafeLimit = 10000 ether;
    uint256 constant public initialPrice = 17500;
    uint256 constant public finalPrice = 10000;    
    uint256 constant public priceStages = 4;

    MiniMeToken public DLT;
    uint256 public startBlock;
    uint256 public endBlock;

    address public destEthDevs;

    address public destTokensDevs;
    address public destTokensReserve;
    address public dltController;

    uint256 public totalCollected;

    uint256 public finalizedBlock;
    uint256 public finalizedTime;

    bool public paused;

    modifier initialized() {
        require(address(DLT) != 0x0);
        _;
    }

    modifier contributionOpen() {
        require(getBlockNumber() >= startBlock &&
                getBlockNumber() <= endBlock &&
                finalizedBlock == 0 &&
                address(DLT) != 0x0);
        _;
    }

    modifier notPaused() {
        require(!paused);
        _;
    }

    function DLTContribution() {
        paused = false;
    }


    /// @notice This method should be called by the owner before the contribution
    ///  period starts This initializes most of the parameters
    /// @param _dlt Address of the DLT token contract
    /// @param _dltController Token controller for the DLT that will be transferred after
    ///  the contribution finalizes.
    /// @param _startBlock Block when the contribution period starts
    /// @param _endBlock The last block that the contribution period is active
    /// @param _destEthDevs Destination address where the contribution ether is sent
    /// @param _destTokensReserve Address where the tokens for the reserve are sent
    /// @param _destTokensDevs Address where the tokens for the dev are sent
    function initialize(
        address _dlt,
        address _dltController,

        uint256 _startBlock,
        uint256 _endBlock,

        address _destEthDevs,

        address _destTokensReserve,
        address _destTokensDevs
    ) public onlyOwner {
        // Initialize only once
        require(address(DLT) == 0x0);

        DLT = MiniMeToken(_dlt);
        require(DLT.totalSupply() == 0);
        require(DLT.controller() == address(this));
        require(DLT.decimals() == 18);  // Same amount of decimals as ETH

        require(_dltController != 0x0);
        dltController = _dltController;

        require(_startBlock >= getBlockNumber());
        require(_startBlock < _endBlock);
        startBlock = _startBlock;
        endBlock = _endBlock;

        require(_destEthDevs != 0x0);
        destEthDevs = _destEthDevs;

        require(_destTokensReserve != 0x0);
        destTokensReserve = _destTokensReserve;

        require(_destTokensDevs != 0x0);
        destTokensDevs = _destTokensDevs;
    }

    /// @notice If anybody sends Ether directly to this contract, consider he is
    ///  getting DLTs.
    function () public payable notPaused {
        proxyPayment(msg.sender);
    }

    // @notice Get the price for a DLT token at any given block number
    // @param _blockNumber the block for which the price is requested
    // @return Number of wei-DLT for 1 wei
    // If sale isn't ongoing for that block, returns 0.
    function getPrice(uint256 _blockNumber) constant public returns (uint256) {
        if (_blockNumber < startBlock || _blockNumber >= endBlock) return 0;

        return priceForStage(stageForBlock(_blockNumber));
    }

    // @notice Get what the stage is for a given blockNumber
    // @param _blockNumber: Block number
    // @return The sale stage for that block. Stage is between 0 and (priceStages - 1)
    function stageForBlock(uint256 _blockNumber) constant internal returns (uint256) {
        uint blockN = _blockNumber.sub(startBlock);
        uint totalBlocks = endBlock.sub(startBlock);

        return priceStages.mul(blockN).div(totalBlocks);
    }

    // @notice Get what the price is for a given stage
    // @param _stage: Stage number
    // @return Price in wei for that stage.
    // If sale stage doesn't exist, returns 0.
    function priceForStage(uint256 _stage) constant internal returns (uint256) {
        if (_stage >= priceStages) return 0;
        uint priceDifference = initialPrice.sub(finalPrice);
        uint stageDelta = priceDifference.div(uint256(priceStages - 1));
        return initialPrice.sub(_stage.mul(stageDelta));
    }

    //////////
    // MiniMe Controller functions
    //////////

    /// @notice This method will generally be called by the DLT token contract to
    ///  acquire DLTs. Or directly from third parties that want to acquire DLTs in
    ///  behalf of a token holder.
    /// @param _th DLT holder where the DLTs will be minted.
    function proxyPayment(address _th) public payable notPaused initialized contributionOpen returns (bool) {
        require(_th != 0x0);
        buyTokens(_th);
        return true;
    }

    function onTransfer(address, address, uint256) public returns (bool) {
        return false;
    }

    function onApprove(address, address, uint256) public returns (bool) {
        return false;
    }

    function buyTokens(address _th) internal {
        // Antispam mechanism
        address caller;
        if (msg.sender == address(DLT)) {
            caller = _th;
        } else {
            caller = msg.sender;
        }

        // Do not allow contracts to game the system
        require(!isContract(caller));

        totalCollected = totalCollected.add(msg.value);
        doBuy(_th, msg.value);
    }

    function doBuy(address _th, uint256 _toFund) internal {
        assert(msg.value >= _toFund);  // Not needed, but double check.
        assert(totalCollected <= failSafeLimit);

        if (_toFund > 0) {
            uint256 price = getPrice(getBlockNumber());
            if (_toFund >= 3 ether) {
                // Apply a bonus of 30% for contributions of at least 3 ethers
                price = price.mul(13).div(10);
            }
            uint256 tokensGenerated = _toFund.mul(price);
            assert(DLT.generateTokens(_th, tokensGenerated));
            destEthDevs.transfer(_toFund);
            NewSale(_th, _toFund, tokensGenerated);
        }
    }

    // NOTE on Percentage format
    // Right now, Solidity does not support decimal numbers. (This will change very soon)
    //  So in this contract we use a representation of a percentage that consist in
    //  expressing the percentage in "x per 10**18"
    // This format has a precision of 16 digits for a percent.
    // Examples:
    //  3%   =   3*(10**16)
    //  100% = 100*(10**16) = 10**18
    //
    // To get a percentage of a value we do it by first multiplying it by the percentage in  (x per 10^18)
    //  and then divide it by 10**18
    //
    //              Y * X(in x per 10**18)
    //  X% of Y = -------------------------
    //               100(in x per 10**18)
    //


    /// @notice This method can be called by the owner before the contribution period
    ///  end or by anybody after the `endBlock`. This method finalizes the contribution period
    ///  by creating the remaining tokens and transferring the controller to the configured
    ///  controller.
    function finalize() public initialized {
        require(getBlockNumber() >= startBlock);
        require(msg.sender == owner || getBlockNumber() > endBlock);
        require(finalizedBlock == 0);

        // Allow premature finalization if final limit is reached
        if (getBlockNumber() <= endBlock) {
            require(totalCollected >= failSafeLimit);
        }

        finalizedBlock = getBlockNumber();
        finalizedTime = now;

        uint256 percentageToDevs = percent(10);

        uint256 percentageToContributors = percent(75);

        uint256 percentageToReserve = percent(15);


        // DLT.totalSupply() -> Tokens minted during the contribution
        //  totalTokens  -> Total tokens that should be after the allocation
        //                   of devTokens and reserve
        //  percentageToContributors -> Which percentage should go to the
        //                               contribution participants
        //                               (x per 10**18 format)
        //  percent(100) -> 100% in (x per 10**18 format)
        //
        //                       percentageToContributors
        //  DLT.totalSupply() = -------------------------- * totalTokens  =>
        //                             percent(100)
        //
        //
        //                            percent(100)
        //  =>  totalTokens = ---------------------------- * DLT.totalSupply()
        //                      percentageToContributors
        //
        uint256 totalTokens = DLT.totalSupply().mul(percent(100)).div(percentageToContributors);


        // Generate tokens for reserve.

        //
        //                    percentageToReserve
        //  reserveTokens = ----------------------- * totalTokens
        //                      percentage(100)
        //
        assert(DLT.generateTokens(
            destTokensReserve,
            totalTokens.mul(percentageToReserve).div(percent(100))));


        //
        //                   percentageToDevs
        //  devTokens = ----------------------- * totalTokens
        //                   percentage(100)
        //
        assert(DLT.generateTokens(
            destTokensDevs,
            totalTokens.mul(percentageToDevs).div(percent(100))));

        DLT.changeController(dltController);

        Finalized();
    }

    function percent(uint256 p) internal returns (uint256) {
        return p.mul(10**16);
    }

    /// @dev Internal function to determine if an address is a contract
    /// @param _addr The address being queried
    /// @return True if `_addr` is a contract
    function isContract(address _addr) constant internal returns (bool) {
        if (_addr == 0) return false;
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }


    //////////
    // Constant functions
    //////////

    /// @return Total tokens issued in weis.
    function tokensIssued() public constant returns (uint256) {
        return DLT.totalSupply();
    }

    //////////
    // Testing specific methods
    //////////

    /// @notice This function is overridden by the test Mocks.
    function getBlockNumber() internal constant returns (uint256) {
        return block.number;
    }


    //////////
    // Safety Methods
    //////////

    /// @notice This method can be used by the controller to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token) public onlyOwner {
        if (DLT.controller() == address(this)) {
            DLT.claimTokens(_token);
        }
        if (_token == 0x0) {
            owner.transfer(this.balance);
            return;
        }

        ERC20Token token = ERC20Token(_token);
        uint256 balance = token.balanceOf(this);
        token.transfer(owner, balance);
        ClaimedTokens(_token, owner, balance);
    }


    /// @notice Pauses the contribution if there is any issue
    function pauseContribution() onlyOwner {
        paused = true;
    }

    /// @notice Resumes the contribution
    function resumeContribution() onlyOwner {
        paused = false;
    }

    event ClaimedTokens(address indexed _token, address indexed _controller, uint256 _amount);
    event NewSale(address indexed _th, uint256 _amount, uint256 _tokens);
    event Finalized();
}
