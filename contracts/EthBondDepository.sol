// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './libraries/EthOwnable.sol';
import './libraries/LowGasSafeMath.sol';
import './libraries/Address.sol';
import './interfaces/IERC20.sol';
import './libraries/SafeERC20.sol';
import './libraries/FullMath.sol';
import './libraries/FixedPoint.sol';
import './interfaces/ITreasury.sol';
import './interfaces/IStaking.sol';
import './interfaces/IStakingHelper.sol';
import './interfaces/AggregatorV3Interface.sol';
import './interfaces/IWAVAX9.sol';


contract TimeBondDepository is Ownable {

    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWAVAX9;
    using LowGasSafeMath for uint;
    using LowGasSafeMath for uint32;




    /* ======== EVENTS ======== */

    event BondCreated( uint deposit, uint indexed payout, uint indexed expires, uint indexed priceInUSD );
    event BondRedeemed( address indexed recipient, uint payout, uint remaining );
    event BondPriceChanged( uint indexed priceInUSD, uint indexed internalPrice, uint indexed debtRatio );
    event ControlVariableAdjustment( uint initialBCV, uint newBCV, uint adjustment, bool addition );




    /* ======== STATE VARIABLES ======== */
    IERC20 public immutable Time; // token given as payment for bond
    IWAVAX9 public immutable principle; // token used to create bond
    ITreasury public immutable treasury; // mints Time when receives principle
    address public immutable DAO; // receives profit share from bond

    AggregatorV3Interface public priceFeed;

    IStaking public staking; // to auto-stake payout
    IStakingHelper public stakingHelper; // to stake and claim if no staking warmup
    bool public useHelper;

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping( address => Bond ) public bondInfo; // stores bond information for depositors

    uint public totalDebt; // total value of outstanding bonds; used for pricing
    uint32 public lastDecay; // reference time for debt decay


    mapping (address => bool) public allowedZappers;


    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint controlVariable; // scaling variable for price
        uint minimumPrice; // vs principle value. 4 decimals (1500 = 0.15)
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint maxDebt; // 9 decimal debt ratio, max % total supply created as debt
        uint32 vestingTerm; // in seconds
    }

    // Info for bond holder
    struct Bond {
        uint payout; // Time remaining to be paid
        uint pricePaid; // In DAI, for front end viewing
        uint32 vesting; // Seconds left to vest
        uint32 lastTime; // Last interaction
    }

    // Info for incremental adjustments to control variable 
    struct Adjust {
        bool add; // addition or subtraction
        uint rate; // increment
        uint target; // BCV when adjustment finished
        uint32 buffer; // minimum length (in seconds) between adjustments
        uint32 lastTime; // time when last adjustment made
    }




    /* ======== INITIALIZATION ======== */

    constructor ( 
        address _Time,
        address _principle,
        address _treasury, 
        address _DAO,
        address _feed
    ) {
        require( _Time != address(0) );
        Time = IERC20(_Time);
        require( _principle != address(0) );
        principle = IWAVAX9(_principle);
        require( _treasury != address(0) );
        treasury = ITreasury(_treasury);
        require( _DAO != address(0) );
        DAO = _DAO;
        require( _feed != address(0) );
        priceFeed = AggregatorV3Interface( _feed );
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _maxDebt uint
     */
    function initializeBondTerms( 
        uint _controlVariable, 
        uint _minimumPrice,
        uint _maxPayout,
        uint _maxDebt,
        uint32 _vestingTerm
    ) external onlyPolicy() {
        require( currentDebt() == 0, "Debt must be 0 for initialization" );
        require( _controlVariable >= 40, "Can lock adjustment" );
        require( _maxPayout <= 1000, "Payout cannot be above 1 percent" );
        require( _vestingTerm >= 129600, "Vesting must be longer than 36 hours" );
        terms = Terms ({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            maxDebt: _maxDebt
        });
        lastDecay = uint32(block.timestamp);
    }



    
    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER { VESTING, PAYOUT, DEBT, MINPRICE }
    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms ( PARAMETER _parameter, uint _input ) external onlyPolicy() {
        if ( _parameter == PARAMETER.VESTING ) { // 0
            require( _input >= 129600, "Vesting must be longer than 36 hours" );
            terms.vestingTerm = uint32(_input);
        } else if ( _parameter == PARAMETER.PAYOUT ) { // 1
            require( _input <= 1000, "Payout cannot be above 1 percent" );
            terms.maxPayout = _input;
        } else if ( _parameter == PARAMETER.DEBT ) { // 2
            terms.maxDebt = _input;
        } else if ( _parameter == PARAMETER.MINPRICE ) { // 3
            terms.minimumPrice = _input;
        }
    }

    /**
     *  @notice set control variable adjustment
     *  @param _addition bool
     *  @param _increment uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment ( 
        bool _addition,
        uint _increment, 
        uint _target,
        uint32 _buffer 
    ) external onlyPolicy() {
        require( _increment <= terms.controlVariable.mul( 25 )/ 1000, "Increment too large" );
        require(_target >= 40, "Next Adjustment could be locked");
        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastTime: uint32(block.timestamp)
        });
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     *  @param _helper bool
     */
    function setStaking( address _staking, bool _helper ) external onlyPolicy() {
        require( _staking != address(0) , "IA");
        if ( _helper ) {
            useHelper = true;
            stakingHelper = IStakingHelper(_staking);
        } else {
            useHelper = false;
            staking = IStaking(_staking);
        }
    }

    function allowZapper(address zapper) external onlyPolicy {
        require(zapper != address(0), "ZNA");
        
        allowedZappers[zapper] = true;
    }

    function removeZapper(address zapper) external onlyPolicy {
       
        allowedZappers[zapper] = false;
    }


    

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit( 
        uint _amount, 
        uint _maxPrice,
        address _depositor
    ) external payable returns ( uint ) {
        require( _depositor != address(0), "Invalid address" );
        require(msg.sender == _depositor || allowedZappers[msg.sender], "LFNA");
        decayDebt();
        require( totalDebt <= terms.maxDebt, "Max capacity reached" );
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = _bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = treasury.valueOf( address(principle), _amount );
        uint payout = payoutFor( value ); // payout to bonder is computed

        require( payout >= 10000000, "Bond too small" ); // must be > 0.01 Time ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        /**
            asset carries risk and is not minted against
            asset transfered to treasury and rewards minted as payout
         */
        if (address(this).balance >= _amount) {
            // pay with WETH9
            require(msg.value == _amount, "UA");
            principle.deposit{value: _amount}(); // wrap only what is needed to pay
            principle.transfer(address(treasury), _amount);
        } else {
            principle.safeTransferFrom( msg.sender, address(treasury), _amount );
        }
        
        treasury.mintRewards( address(this), payout );
        
        // total debt is increased
        totalDebt = totalDebt.add( value ); 
                
        // depositor info is stored
        bondInfo[ _depositor ] = Bond({ 
            payout: bondInfo[ _depositor ].payout.add( payout ),
            vesting: terms.vestingTerm,
            lastTime: uint32(block.timestamp),
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated( _amount, payout, block.timestamp.add( terms.vestingTerm ), priceInUSD );
        emit BondPriceChanged( bondPriceInUSD(), _bondPrice(), debtRatio() );

        adjust(); // control variable is adjusted
        return payout; 
    }

    /** 
     *  @notice redeem bond for user
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */ 
    function redeem( address _recipient, bool _stake ) external returns ( uint ) { 
        require(msg.sender == _recipient, "NA");       
        Bond memory info = bondInfo[ _recipient ];
        uint percentVested = percentVestedFor( _recipient ); // (seconds since last interaction / vesting term remaining)

        if ( percentVested >= 10000 ) { // if fully vested
            delete bondInfo[ _recipient ]; // delete user info
            emit BondRedeemed( _recipient, info.payout, 0 ); // emit bond data
            return stakeOrSend( _recipient, _stake, info.payout ); // pay user everything due

        } else { // if unfinished
            // calculate payout vested
            uint payout = info.payout.mul( percentVested )/ 10000;

            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                payout: info.payout.sub( payout ),
                vesting: info.vesting.sub32( uint32( block.timestamp ).sub32( info.lastTime ) ),
                lastTime: uint32( block.timestamp ),
                pricePaid: info.pricePaid
            });

            emit BondRedeemed( _recipient, payout, bondInfo[ _recipient ].payout );
            return stakeOrSend( _recipient, _stake, payout );
        }
    }



    
    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param _stake bool
     *  @param _amount uint
     *  @return uint
     */
    function stakeOrSend( address _recipient, bool _stake, uint _amount ) internal returns ( uint ) {
        if ( !_stake ) { // if user does not want to stake
            Time.transfer( _recipient, _amount ); // send payout
        } else { // if user wants to stake
            if ( useHelper ) { // use if staking warmup is 0
                Time.approve( address(stakingHelper), _amount );
                stakingHelper.stake( _amount, _recipient );
            } else {
                Time.approve( address(staking), _amount );
                staking.stake( _amount, _recipient );
            }
        }
        return _amount;
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() internal {
         uint timeCanAdjust = adjustment.lastTime.add32( adjustment.buffer );
         if( adjustment.rate != 0 && block.timestamp >= timeCanAdjust ) {
            uint initial = terms.controlVariable;
            if ( adjustment.add ) {
                terms.controlVariable = terms.controlVariable.add( adjustment.rate );
                if ( terms.controlVariable >= adjustment.target ) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub( adjustment.rate );
                if ( terms.controlVariable <= adjustment.target ) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastTime = uint32(block.timestamp);
            emit ControlVariableAdjustment( initial, terms.controlVariable, adjustment.rate, adjustment.add );
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt.sub( debtDecay() );
        lastDecay = uint32(block.timestamp);
    }




    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns ( uint ) {
        return Time.totalSupply().mul( terms.maxPayout )/ 100000;
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor( uint _value ) public view returns ( uint ) {
        return FixedPoint.fraction( _value, bondPrice() ).decode112with18()/ 1e14;
    }


    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns ( uint price_ ) {        
        price_ = terms.controlVariable.mul( debtRatio() )/ 1e5;
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;
        }
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _bondPrice() internal returns ( uint price_ ) {
        price_ = terms.controlVariable.mul( debtRatio() ).add( 1000000000 ) / 1e7;
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;        
        } else if ( terms.minimumPrice != 0 ) {
            terms.minimumPrice = 0;
        }
    }

    /**
     *  @notice get asset price from chainlink
     */
    function assetPrice() public view returns (int) {
        ( , int price, , , ) = priceFeed.latestRoundData();
        return price;
    }

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns ( uint price_ ) {
        price_ = bondPrice().mul( uint( assetPrice() ) ).mul( 1e6 );
    }


    /**
     *  @notice calculate current ratio of debt to Time supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns ( uint debtRatio_ ) {   
        uint supply = Time.totalSupply();
        debtRatio_ = FixedPoint.fraction( 
            currentDebt().mul( 1e9 ), 
            supply
        ).decode112with18()/ 1e18;
    }

    /**
     *  @notice debt ratio in same terms as reserve bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns ( uint ) {
        return debtRatio().mul( uint( assetPrice() ) )/ 10**priceFeed.decimals(); // ETH feed is 8 decimals
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns ( uint ) {
        return totalDebt.sub( debtDecay() );
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns ( uint decay_ ) {
        uint32 timeSinceLast = uint32(block.timestamp).sub32( lastDecay );
        decay_ = totalDebt.mul( timeSinceLast )/ terms.vestingTerm;
        if ( decay_ > totalDebt ) {
            decay_ = totalDebt;
        }
    }


    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor( address _depositor ) public view returns ( uint percentVested_ ) {
        Bond memory bond = bondInfo[ _depositor ];
        uint secondsSinceLast = uint32(block.timestamp).sub32( bond.lastTime );
        uint vesting = bond.vesting;

        if ( vesting > 0 ) {
            percentVested_ = secondsSinceLast.mul( 10000 )/vesting;
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of Time available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor( address _depositor ) external view returns ( uint pendingPayout_ ) {
        uint percentVested = percentVestedFor( _depositor );
        uint payout = bondInfo[ _depositor ].payout;

        if ( percentVested >= 10000 ) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout.mul( percentVested )/ 10000;
        }
    }




    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or Time) to the DAO
     *  @return bool
     */
    function recoverLostToken( IERC20 _token ) external returns ( bool ) {
        require( _token != Time, "NAT" );
        require( _token != principle, "NAP" );
        _token.safeTransfer( DAO, _token.balanceOf( address(this) ) );
        return true;
    }

    function recoverLostETH() internal {
        if (address(this).balance > 0) safeTransferETH(DAO, address(this).balance);
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'STE');
    }
}