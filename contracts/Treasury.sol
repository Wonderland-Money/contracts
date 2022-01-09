// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './libraries/LowGasSafeMath.sol';
import './libraries/Address.sol';
import './libraries/Ownable.sol';
import './interfaces/IERC20.sol';
import './libraries/SafeERC20.sol';
import './interfaces/ITIMEERC20.sol';
import './interfaces/IBondCalculator.sol';


contract TimeTreasury is Ownable {

    using LowGasSafeMath for uint;
    using LowGasSafeMath for uint32;
    using SafeERC20 for IERC20;

    event Deposit( address indexed token, uint amount, uint value );
    event Withdrawal( address indexed token, uint amount, uint value );
    event CreateDebt( address indexed debtor, address indexed token, uint amount, uint value );
    event RepayDebt( address indexed debtor, address indexed token, uint amount, uint value );
    event ReservesManaged( address indexed token, uint amount );
    event ReservesUpdated( uint indexed totalReserves );
    event ReservesAudited( uint indexed totalReserves );
    event RewardsMinted( address indexed caller, address indexed recipient, uint amount );
    event ChangeQueued( MANAGING indexed managing, address queued );
    event ChangeActivated( MANAGING indexed managing, address activated, bool result );
    event ChangeLimitAmount( uint256 amount );

    enum MANAGING { 
        RESERVEDEPOSITOR, 
        RESERVESPENDER, 
        RESERVETOKEN, 
        RESERVEMANAGER, 
        LIQUIDITYDEPOSITOR, 
        LIQUIDITYTOKEN, 
        LIQUIDITYMANAGER, 
        DEBTOR, 
        REWARDMANAGER, 
        SOHM 
    }

    ITIMEERC20 public immutable Time;
    uint32 public immutable secondsNeededForQueue;

    address[] public reserveTokens; // Push only, beware false-positives.
    mapping( address => bool ) public isReserveToken;
    mapping( address => uint32 ) public reserveTokenQueue; // Delays changes to mapping.

    address[] public reserveDepositors; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isReserveDepositor;
    mapping( address => uint32 ) public reserveDepositorQueue; // Delays changes to mapping.

    address[] public reserveSpenders; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isReserveSpender;
    mapping( address => uint32 ) public reserveSpenderQueue; // Delays changes to mapping.

    address[] public liquidityTokens; // Push only, beware false-positives.
    mapping( address => bool ) public isLiquidityToken;
    mapping( address => uint32 ) public LiquidityTokenQueue; // Delays changes to mapping.

    address[] public liquidityDepositors; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isLiquidityDepositor;
    mapping( address => uint32 ) public LiquidityDepositorQueue; // Delays changes to mapping.

    mapping( address => address ) public bondCalculator; // bond calculator for liquidity token

    address[] public reserveManagers; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isReserveManager;
    mapping( address => uint32 ) public ReserveManagerQueue; // Delays changes to mapping.

    address[] public liquidityManagers; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isLiquidityManager;
    mapping( address => uint32 ) public LiquidityManagerQueue; // Delays changes to mapping.

    address[] public debtors; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isDebtor;
    mapping( address => uint32 ) public debtorQueue; // Delays changes to mapping.
    mapping( address => uint ) public debtorBalance;

    address[] public rewardManagers; // Push only, beware false-positives. Only for viewing.
    mapping( address => bool ) public isRewardManager;
    mapping( address => uint32 ) public rewardManagerQueue; // Delays changes to mapping.

    mapping( address => uint256 ) public hourlyLimitAmounts; // tracks amounts
    mapping( address => uint32 ) public hourlyLimitQueue; // Delays changes to mapping.

    uint256 public limitAmount;

    IERC20 public MEMOries;
    uint public sOHMQueue; // Delays change to sOHM address
    
    uint public totalReserves; // Risk-free value of all assets
    uint public totalDebt;

    constructor (
        address _Time,
        address _MIM,
        uint32 _secondsNeededForQueue,
        uint256 _limitAmount
    ) {
        require( _Time != address(0) );
        Time = ITIMEERC20(_Time);

        isReserveToken[ _MIM ] = true;
        reserveTokens.push( _MIM );

    //    isLiquidityToken[ _OHMDAI ] = true;
    //    liquidityTokens.push( _OHMDAI );

        secondsNeededForQueue = _secondsNeededForQueue;
        limitAmount = _limitAmount;
    }

    function setLimitAmount(uint amount) external onlyOwner {
        limitAmount = amount;
        emit ChangeLimitAmount(limitAmount);
    }

    /**
        @notice allow approved address to deposit an asset for Time
        @param _amount uint
        @param _token address
        @param _profit uint
        @return send_ uint
     */
    function deposit( uint _amount, address _token, uint _profit ) external returns ( uint send_ ) {
        require( isReserveToken[ _token ] || isLiquidityToken[ _token ], "Not accepted" );
        IERC20( _token ).safeTransferFrom( msg.sender, address(this), _amount );

        if ( isReserveToken[ _token ] ) {
            require( isReserveDepositor[ msg.sender ], "Not approved" );
        } else {
            require( isLiquidityDepositor[ msg.sender ], "Not approved" );
        }

        uint value = valueOf(_token, _amount);
        // mint Time needed and store amount of rewards for distribution
        send_ = value.sub( _profit );
        limitRequirements(msg.sender, send_);
        Time.mint( msg.sender, send_ );

        totalReserves = totalReserves.add( value );
        emit ReservesUpdated( totalReserves );

        emit Deposit( _token, _amount, value );
    }

    /**
        @notice allow approved address to burn Time for reserves
        @param _amount uint
        @param _token address
     */
    function withdraw( uint _amount, address _token ) external {
        require( isReserveToken[ _token ], "Not accepted" ); // Only reserves can be used for redemptions
        require( isReserveSpender[ msg.sender ], "Not approved" );

        uint value = valueOf( _token, _amount );
        Time.burnFrom( msg.sender, value );

        totalReserves = totalReserves.sub( value );
        emit ReservesUpdated( totalReserves );

        IERC20( _token ).safeTransfer( msg.sender, _amount );

        emit Withdrawal( _token, _amount, value );
    }

    /**
        @notice allow approved address to borrow reserves
        @param _amount uint
        @param _token address
     */
    function incurDebt( uint _amount, address _token ) external {
        require( isDebtor[ msg.sender ], "Not approved" );
        require( isReserveToken[ _token ], "Not accepted" );

        uint value = valueOf( _token, _amount );

        uint maximumDebt = MEMOries.balanceOf( msg.sender ); // Can only borrow against sOHM held
        uint balance = debtorBalance[ msg.sender ];
        uint availableDebt = maximumDebt.sub( balance );
        require( value <= availableDebt, "Exceeds debt limit" );
        limitRequirements(msg.sender, value);
        debtorBalance[ msg.sender ] = balance.add( value );
        totalDebt = totalDebt.add( value );

        totalReserves = totalReserves.sub( value );
        emit ReservesUpdated( totalReserves );
        
        IERC20( _token ).safeTransfer( msg.sender, _amount );
        
        emit CreateDebt( msg.sender, _token, _amount, value );
    }

    /**
        @notice allow approved address to repay borrowed reserves with reserves
        @param _amount uint
        @param _token address
     */
    function repayDebtWithReserve( uint _amount, address _token ) external {
        require( isDebtor[ msg.sender ], "Not approved" );
        require( isReserveToken[ _token ], "Not accepted" );

        IERC20( _token ).safeTransferFrom( msg.sender, address(this), _amount );

        uint value = valueOf( _token, _amount );
        debtorBalance[ msg.sender ] = debtorBalance[ msg.sender ].sub( value );
        totalDebt = totalDebt.sub( value );

        totalReserves = totalReserves.add( value );
        emit ReservesUpdated( totalReserves );

        emit RepayDebt( msg.sender, _token, _amount, value );
    }

    /**
        @notice allow approved address to repay borrowed reserves with Time
        @param _amount uint
     */
    function repayDebtWithTime( uint _amount ) external {
        require( isDebtor[ msg.sender ], "Not approved as debtor" );
        require( isReserveSpender[ msg.sender ], "Not approved as spender" );

        Time.burnFrom( msg.sender, _amount );

        debtorBalance[ msg.sender ] = debtorBalance[ msg.sender ].sub( _amount );
        totalDebt = totalDebt.sub( _amount );

        emit RepayDebt( msg.sender, address(Time), _amount, _amount );
    }

    /**
        @notice allow approved address to withdraw assets
        @param _token address
        @param _amount uint
     */
    function manage( address _token, uint _amount ) external {
        uint value = valueOf(_token, _amount);
        if( isLiquidityToken[ _token ] ) {
            require( isLiquidityManager[ msg.sender ], "Not approved" );
            require(value <= excessReserves());
        } else {
            if (isReserveToken[ _token ]) require(value <= excessReserves());
            require( isReserveManager[ msg.sender ], "Not approved" );
        }
        
        limitRequirements(msg.sender, value);
        totalReserves = totalReserves.sub( value );
        emit ReservesUpdated( totalReserves );

        IERC20( _token ).safeTransfer( msg.sender, _amount );

        emit ReservesManaged( _token, _amount );
    }

    /**
        @notice send epoch reward to staking contract
     */
    function mintRewards( address _recipient, uint _amount ) external {
        require( isRewardManager[ msg.sender ], "Not approved" );
        require( _amount <= excessReserves(), "Insufficient reserves" );
        limitRequirements(msg.sender, _amount);
        Time.mint( _recipient, _amount );

        emit RewardsMinted( msg.sender, _recipient, _amount );
    } 

    /**
        @notice returns excess reserves not backing tokens
        @return uint
     */
    function excessReserves() public view returns ( uint ) {
        return totalReserves.sub( Time.totalSupply().sub( totalDebt ) );
    }

    /**
        @notice takes inventory of all tracked assets
        @notice always consolidate to recognized reserves before audit
     */
    function auditReserves() external onlyOwner {
        uint reserves;
        for( uint i = 0; i < reserveTokens.length; i++ ) {
            reserves = reserves.add ( 
                valueOf( reserveTokens[ i ], IERC20( reserveTokens[ i ] ).balanceOf( address(this) ) )
            );
        }
        for( uint i = 0; i < liquidityTokens.length; i++ ) {
            reserves = reserves.add (
                valueOf( liquidityTokens[ i ], IERC20( liquidityTokens[ i ] ).balanceOf( address(this) ) )
            );
        }
        totalReserves = reserves;
        emit ReservesUpdated( reserves );
        emit ReservesAudited( reserves );
    }

    /**
        @notice returns Time valuation of asset
        @param _token address
        @param _amount uint
        @return value_ uint
     */
    function valueOf( address _token, uint _amount ) public view returns ( uint value_ ) {
        if ( isReserveToken[ _token ] ) {
            // convert amount to match Time decimals
            value_ = _amount.mul( 10 ** Time.decimals() ).div( 10 ** IERC20( _token ).decimals() );
        } else if ( isLiquidityToken[ _token ] ) {
            value_ = IBondCalculator( bondCalculator[ _token ] ).valuation( _token, _amount );
        }
    }

    /**
        @notice queue address to change boolean in mapping
        @param _managing MANAGING
        @param _address address
        @return bool
     */
    function queue( MANAGING _managing, address _address ) external onlyOwner returns ( bool ) {
        require( _address != address(0), "IA" );
        if ( _managing == MANAGING.RESERVEDEPOSITOR ) { // 0
            reserveDepositorQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.RESERVESPENDER ) { // 1
            reserveSpenderQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.RESERVETOKEN ) { // 2
            reserveTokenQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.RESERVEMANAGER ) { // 3
            ReserveManagerQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue.mul32( 2 ) );
        } else if ( _managing == MANAGING.LIQUIDITYDEPOSITOR ) { // 4
            LiquidityDepositorQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 5
            LiquidityTokenQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.LIQUIDITYMANAGER ) { // 6
            LiquidityManagerQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue.mul32( 2 ) );
        } else if ( _managing == MANAGING.DEBTOR ) { // 7
            debtorQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.REWARDMANAGER ) { // 8
            rewardManagerQueue[ _address ] = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else if ( _managing == MANAGING.SOHM ) { // 9
            sOHMQueue = uint32(block.timestamp).add32( secondsNeededForQueue );
        } else return false;

        emit ChangeQueued( _managing, _address );
        return true;
    }

    /**
        @notice verify queue then set boolean in mapping
        @param _managing MANAGING
        @param _address address
        @param _calculator address
        @return bool
     */
    function toggle(
        MANAGING _managing, 
        address _address, 
        address _calculator 
    ) external onlyOwner returns ( bool ) {
        require( _address != address(0), "IA" );
        bool result;
        if ( _managing == MANAGING.RESERVEDEPOSITOR ) { // 0
            if ( requirements( reserveDepositorQueue, isReserveDepositor, _address ) ) {
                reserveDepositorQueue[ _address ] = 0;
                if( !listContains( reserveDepositors, _address ) ) {
                    reserveDepositors.push( _address );
                }
            }
            result = !isReserveDepositor[ _address ];
            isReserveDepositor[ _address ] = result;
            
        } else if ( _managing == MANAGING.RESERVESPENDER ) { // 1
            if ( requirements( reserveSpenderQueue, isReserveSpender, _address ) ) {
                reserveSpenderQueue[ _address ] = 0;
                if( !listContains( reserveSpenders, _address ) ) {
                    reserveSpenders.push( _address );
                }
            }
            result = !isReserveSpender[ _address ];
            isReserveSpender[ _address ] = result;

        } else if ( _managing == MANAGING.RESERVETOKEN ) { // 2
            if ( requirements( reserveTokenQueue, isReserveToken, _address ) ) {
                reserveTokenQueue[ _address ] = 0;
                if( !listContains( reserveTokens, _address ) && !listContains( liquidityTokens, _address ) ) {
                    reserveTokens.push( _address );
                }
            }
            result = !isReserveToken[ _address ];
            require(!result || !isLiquidityToken[_address], "Do not add to both types of token");
            isReserveToken[ _address ] = result;

        } else if ( _managing == MANAGING.RESERVEMANAGER ) { // 3
            if ( requirements( ReserveManagerQueue, isReserveManager, _address ) ) {
                reserveManagers.push( _address );
                ReserveManagerQueue[ _address ] = 0;
                if( !listContains( reserveManagers, _address ) ) {
                    reserveManagers.push( _address );
                }
            }
            result = !isReserveManager[ _address ];
            isReserveManager[ _address ] = result;

        } else if ( _managing == MANAGING.LIQUIDITYDEPOSITOR ) { // 4
            if ( requirements( LiquidityDepositorQueue, isLiquidityDepositor, _address ) ) {
                liquidityDepositors.push( _address );
                LiquidityDepositorQueue[ _address ] = 0;
                if( !listContains( liquidityDepositors, _address ) ) {
                    liquidityDepositors.push( _address );
                }
            }
            result = !isLiquidityDepositor[ _address ];
            isLiquidityDepositor[ _address ] = result;

        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 5
            if ( requirements( LiquidityTokenQueue, isLiquidityToken, _address ) ) {
                LiquidityTokenQueue[ _address ] = 0;
                if( !listContains( liquidityTokens, _address ) && !listContains( reserveTokens, _address ) ) {
                    liquidityTokens.push( _address );
                }
            }
            result = !isLiquidityToken[ _address ];
            require(!result || !isReserveToken[_address], "Do not add to both types of token");
            isLiquidityToken[ _address ] = result;
            bondCalculator[ _address ] = _calculator;

        } else if ( _managing == MANAGING.LIQUIDITYMANAGER ) { // 6
            if ( requirements( LiquidityManagerQueue, isLiquidityManager, _address ) ) {
                LiquidityManagerQueue[ _address ] = 0;
                if( !listContains( liquidityManagers, _address ) ) {
                    liquidityManagers.push( _address );
                }
            }
            result = !isLiquidityManager[ _address ];
            isLiquidityManager[ _address ] = result;

        } else if ( _managing == MANAGING.DEBTOR ) { // 7
            if ( requirements( debtorQueue, isDebtor, _address ) ) {
                debtorQueue[ _address ] = 0;
                if( !listContains( debtors, _address ) ) {
                    debtors.push( _address );
                }
            }
            result = !isDebtor[ _address ];
            isDebtor[ _address ] = result;

        } else if ( _managing == MANAGING.REWARDMANAGER ) { // 8
            if ( requirements( rewardManagerQueue, isRewardManager, _address ) ) {
                rewardManagerQueue[ _address ] = 0;
                if( !listContains( rewardManagers, _address ) ) {
                    rewardManagers.push( _address );
                }
            }
            result = !isRewardManager[ _address ];
            isRewardManager[ _address ] = result;

        } else if ( _managing == MANAGING.SOHM ) { // 9
            sOHMQueue = 0;
            MEMOries = IERC20(_address);
            result = true;

        } else return false;

        emit ChangeActivated( _managing, _address, result );
        return true;
    }

    /**
        @notice checks requirements and returns altered structs
        @param queue_ mapping( address => uint )
        @param status_ mapping( address => bool )
        @param _address address
        @return bool 
     */
    function requirements( 
        mapping( address => uint32 ) storage queue_, 
        mapping( address => bool ) storage status_, 
        address _address 
    ) internal view returns ( bool ) {
        if ( !status_[ _address ] ) {
            require( queue_[ _address ] != 0, "Must queue" );
            require( queue_[ _address ] <= uint32(block.timestamp), "Queue not expired" );
            return true;
        } return false;
    }

    /**
        @notice checks LimitRequirements
        @param _address address
        @param _address value
     */
    function limitRequirements( 
        address _address,
        uint256 value
    ) internal {
        if (block.timestamp.sub(hourlyLimitQueue[_address]) >= 1 hours)
        {
            hourlyLimitAmounts[_address] = limitAmount;
            hourlyLimitQueue[_address] = uint32(block.timestamp);
        }
        hourlyLimitAmounts[_address] = hourlyLimitAmounts[_address].sub(value);
    }

    /**
        @notice checks array to ensure against duplicate
        @param _list address[]
        @param _token address
        @return bool
     */
    function listContains( address[] storage _list, address _token ) internal view returns ( bool ) {
        for( uint i = 0; i < _list.length; i++ ) {
            if( _list[ i ] == _token ) {
                return true;
            }
        }
        return false;
    }
}