// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
pragma abicoder v2;
import './libraries/Ownable.sol';
import './libraries/LowGasSafeMath.sol';
import './libraries/Address.sol';
import './interfaces/IERC20.sol';
import './libraries/SafeERC20.sol';
import './libraries/FullMath.sol';
import './libraries/FixedPoint.sol';
import './interfaces/ITreasury.sol';
import './interfaces/IBondCalculator.sol';
import './interfaces/IStaking.sol';
import './interfaces/IStakingHelper.sol';

contract TimeBondDepository is Ownable {

    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using LowGasSafeMath for uint;
    using LowGasSafeMath for uint32;




    /* ======== EVENTS ======== */

    event BondCreated( uint deposit, uint indexed payout, uint indexed expires, uint indexed priceInUSD );
    event BondRedeemed( address indexed recipient, uint payout, uint remaining );
    event BondPriceChanged( uint indexed priceInUSD, uint indexed internalPrice, uint indexed debtRatio );
    event ControlVariableAdjustment( uint initialBCV, uint newBCV, uint adjustment, bool addition );
    event InitTerms( Terms terms);
    event LogSetTerms(PARAMETER param, uint value);
    event LogSetAdjustment( Adjust adjust);
    event LogSetStaking( address indexed stakingContract, bool isHelper);
    event LogRecoverLostToken( address indexed tokenToRecover, uint amount);



    /* ======== STATE VARIABLES ======== */

    IERC20 public immutable Time; // token given as payment for bond
    IERC20 public immutable principle; // token used to create bond
    ITreasury public immutable treasury; // mints Time when receives principle
    address public immutable DAO; // receives profit share from bond

    bool public immutable isLiquidityBond; // LP and Reserve bonds are treated slightly different
    IBondCalculator public immutable bondCalculator; // calculates value of LP tokens

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
        uint minimumPrice; // vs principle value
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint maxDebt; // 9 decimal debt ratio, max % total supply created as debt
        uint32 vestingTerm; // in seconds
    }

    // Info for bond holder
    struct Bond {
        uint payout; // Time remaining to be paid
        uint pricePaid; // In DAI, for front end viewing
        uint32 lastTime; // Last interaction
        uint32 vesting; // Seconds left to vest
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
        address _bondCalculator
    ) {
        require( _Time != address(0) );
        Time = IERC20(_Time);
        require( _principle != address(0) );
        principle = IERC20(_principle);
        require( _treasury != address(0) );
        treasury = ITreasury(_treasury);
        require( _DAO != address(0) );
        DAO = _DAO;
        // bondCalculator should be address(0) if not LP bond
        bondCalculator = IBondCalculator(_bondCalculator);
        isLiquidityBond = ( _bondCalculator != address(0) );
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint32
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _fee uint
     *  @param _maxDebt uint
     */
    function initializeBondTerms( 
        uint _controlVariable, 
        uint _minimumPrice,
        uint _maxPayout,
        uint _fee,
        uint _maxDebt,
        uint32 _vestingTerm
    ) external onlyOwner() {
        require( terms.controlVariable == 0, "Bonds must be initialized from 0" );
        require( _controlVariable >= 40, "Can lock adjustment" );
        require( _maxPayout <= 1000, "Payout cannot be above 1 percent" );
        require( _vestingTerm >= 129600, "Vesting must be longer than 36 hours" );
        require( _fee <= 10000, "DAO fee cannot exceed payout" );
        terms = Terms ({
            controlVariable: _controlVariable,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            fee: _fee,
            maxDebt: _maxDebt,
            vestingTerm: _vestingTerm
        });
        lastDecay = uint32(block.timestamp);
        emit InitTerms(terms);
    }



    
    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER { VESTING, PAYOUT, FEE, DEBT, MINPRICE }
    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms ( PARAMETER _parameter, uint _input ) external onlyOwner() {
        if ( _parameter == PARAMETER.VESTING ) { // 0
            require( _input >= 129600, "Vesting must be longer than 36 hours" );
            terms.vestingTerm = uint32(_input);
        } else if ( _parameter == PARAMETER.PAYOUT ) { // 1
            require( _input <= 1000, "Payout cannot be above 1 percent" );
            terms.maxPayout = _input;
        } else if ( _parameter == PARAMETER.FEE ) { // 2
            require( _input <= 10000, "DAO fee cannot exceed payout" );
            terms.fee = _input;
        } else if ( _parameter == PARAMETER.DEBT ) { // 3
            terms.maxDebt = _input;
        } else if ( _parameter == PARAMETER.MINPRICE ) { // 4
            terms.minimumPrice = _input;
        }
        emit LogSetTerms(_parameter, _input);
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
    ) external onlyOwner() {
        require( _increment <= terms.controlVariable.mul( 25 ) / 1000 , "Increment too large" );
        require(_target >= 40, "Next Adjustment could be locked");
        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastTime: uint32(block.timestamp)
        });
        emit LogSetAdjustment(adjustment);
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     *  @param _helper bool
     */
    function setStaking( address _staking, bool _helper ) external onlyOwner() {
        require( _staking != address(0), "IA" );
        if ( _helper ) {
            useHelper = true;
            stakingHelper = IStakingHelper(_staking);
        } else {
            useHelper = false;
            staking = IStaking(_staking);
        }
        emit LogSetStaking(_staking, _helper);
    }

    function allowZapper(address zapper) external onlyOwner {
        require(zapper != address(0), "ZNA");
        
        allowedZappers[zapper] = true;
    }

    function removeZapper(address zapper) external onlyOwner {
       
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
    ) external returns ( uint ) {
        require( _depositor != address(0), "Invalid address" );
        require(msg.sender == _depositor || allowedZappers[msg.sender], "LFNA");
        decayDebt();
        
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = _bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = treasury.valueOf( address(principle), _amount );
        uint payout = payoutFor( value ); // payout to bonder is computed
        require( totalDebt.add(value) <= terms.maxDebt, "Max capacity reached" );
        require( payout >= 10000000, "Bond too small" ); // must be > 0.01 Time ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        // profits are calculated
        uint fee = payout.mul( terms.fee )/ 10000 ;
        uint profit = value.sub( payout ).sub( fee );

        uint balanceBefore = Time.balanceOf(address(this));
        /**
            principle is transferred in
            approved and
            deposited into the treasury, returning (_amount - profit) Time
         */
        principle.safeTransferFrom( msg.sender, address(this), _amount );
        principle.approve( address( treasury ), _amount );
        treasury.deposit( _amount, address(principle), profit );
        
        if ( fee != 0 ) { // fee is transferred to dao 
            Time.safeTransfer( DAO, fee ); 
        }
        require(balanceBefore.add(profit) == Time.balanceOf(address(this)), "Not enough Time to cover profit");
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
        // (seconds since last interaction / vesting term remaining)
        uint percentVested = percentVestedFor( _recipient );

        if ( percentVested >= 10000 ) { // if fully vested
            delete bondInfo[ _recipient ]; // delete user info
            emit BondRedeemed( _recipient, info.payout, 0 ); // emit bond data
            return stakeOrSend( _recipient, _stake, info.payout ); // pay user everything due

        } else { // if unfinished
            // calculate payout vested
            uint payout = info.payout.mul( percentVested ) / 10000 ;
            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                payout: info.payout.sub( payout ),
                vesting: info.vesting.sub32( uint32( block.timestamp ).sub32( info.lastTime ) ),
                lastTime: uint32(block.timestamp),
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
            uint bcv = initial;
            if ( adjustment.add ) {
                bcv = bcv.add(adjustment.rate);
                if ( bcv >= adjustment.target ) {
                    adjustment.rate = 0;
                    bcv = adjustment.target;
                }
            } else {
                bcv = bcv.sub(adjustment.rate);
                if ( bcv <= adjustment.target ) {
                    adjustment.rate = 0;
                    bcv = adjustment.target;
                }
            }
            terms.controlVariable = bcv;
            adjustment.lastTime = uint32(block.timestamp);
            emit ControlVariableAdjustment( initial, bcv, adjustment.rate, adjustment.add );
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
        return Time.totalSupply().mul( terms.maxPayout ) / 100000 ;
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor( uint _value ) public view returns ( uint ) {
        return FixedPoint.fraction( _value, bondPrice() ).decode112with18() / 1e16 ;
    }


    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns ( uint price_ ) {        
        price_ = terms.controlVariable.mul( debtRatio() ).add( 1000000000 ) / 1e7;
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
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns ( uint price_ ) {
        if( isLiquidityBond ) {
            price_ = bondPrice().mul( bondCalculator.markdown( address(principle) ) ) / 100 ;
        } else {
            price_ = bondPrice().mul( 10 ** principle.decimals() ) / 100;
        }
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
        ).decode112with18() / 1e18;
    }

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns ( uint ) {
        if ( isLiquidityBond ) {
            return debtRatio().mul( bondCalculator.markdown( address(principle) ) ) / 1e9;
        } else {
            return debtRatio();
        }
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
        decay_ = totalDebt.mul( timeSinceLast ) / terms.vestingTerm;
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
            percentVested_ = secondsSinceLast.mul( 10000 ) / vesting;
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
            pendingPayout_ = payout.mul( percentVested ) / 10000;
        }
    }




    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or Time) to the DAO
     *  @return bool
     */
    function recoverLostToken(IERC20 _token ) external returns ( bool ) {
        require( _token != Time, "NAT" );
        require( _token != principle, "NAP" );
        uint balance = _token.balanceOf( address(this));
        _token.safeTransfer( DAO,  balance );
        emit LogRecoverLostToken(address(_token), balance);
        return true;
    }
}