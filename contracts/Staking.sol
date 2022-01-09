// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './libraries/LowGasSafeMath.sol';
import './interfaces/IERC20.sol';
import './libraries/Address.sol';
import './libraries/SafeERC20.sol';
import './libraries/Ownable.sol';
import './interfaces/IMemo.sol';
import './interfaces/IWarmup.sol';
import './interfaces/IDistributor.sol';


contract TimeStaking is Ownable {

    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint32;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMemo;

    IERC20 public immutable Time;
    IMemo public immutable Memories;

    struct Epoch {
        uint number;
        uint distribute;
        uint32 length;
        uint32 endTime;
    }
    Epoch public epoch;

    IDistributor public distributor;
    
    uint public totalBonus;
    
    IWarmup public warmupContract;
    uint public warmupPeriod;

    event LogStake(address indexed recipient, uint256 amount);
    event LogClaim(address indexed recipient, uint256 amount);
    event LogForfeit(address indexed recipient, uint256 memoAmount, uint256 timeAmount);
    event LogDepositLock(address indexed user, bool locked);
    event LogUnstake(address indexed recipient, uint256 amount);
    event LogRebase(uint256 distribute);
    event LogSetContract(CONTRACTS contractType, address indexed _contract);
    event LogWarmupPeriod(uint period);
    
    constructor ( 
        address _Time, 
        address _Memories, 
        uint32 _epochLength,
        uint _firstEpochNumber,
        uint32 _firstEpochTime
    ) {
        require( _Time != address(0) );
        Time = IERC20(_Time);
        require( _Memories != address(0) );
        Memories = IMemo(_Memories);
        
        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endTime: _firstEpochTime,
            distribute: 0
        });
    }

    struct Claim {
        uint deposit;
        uint gons;
        uint expiry;
        bool lock; // prevents malicious delays
    }
    mapping( address => Claim ) public warmupInfo;

    /**
        @notice stake Time to enter warmup
        @param _amount uint
        @return bool
     */
    function stake( uint _amount, address _recipient ) external returns ( bool ) {
        rebase();
        
        Time.safeTransferFrom( msg.sender, address(this), _amount );

        Claim memory info = warmupInfo[ _recipient ];
        require( !info.lock, "Deposits for account are locked" );

        warmupInfo[ _recipient ] = Claim ({
            deposit: info.deposit.add( _amount ),
            gons: info.gons.add( Memories.gonsForBalance( _amount ) ),
            expiry: epoch.number.add( warmupPeriod ),
            lock: false
        });
        
        Memories.safeTransfer( address(warmupContract), _amount );
        emit LogStake(_recipient, _amount);
        return true;
    }

    /**
        @notice retrieve MEMO from warmup
        @param _recipient address
     */
    function claim ( address _recipient ) external {
        Claim memory info = warmupInfo[ _recipient ];
        if ( epoch.number >= info.expiry && info.expiry != 0 ) {
            delete warmupInfo[ _recipient ];
            uint256 amount = Memories.balanceForGons( info.gons );
            warmupContract.retrieve( _recipient,  amount);
            emit LogClaim(_recipient, amount);
        }
    }

    /**
        @notice forfeit MEMO in warmup and retrieve Time
     */
    function forfeit() external {
        Claim memory info = warmupInfo[ msg.sender ];
        delete warmupInfo[ msg.sender ];
        uint memoBalance = Memories.balanceForGons( info.gons );
        warmupContract.retrieve( address(this),  memoBalance);
        Time.safeTransfer( msg.sender, info.deposit);
        emit LogForfeit(msg.sender, memoBalance, info.deposit);
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[ msg.sender ].lock = !warmupInfo[ msg.sender ].lock;
        emit LogDepositLock(msg.sender, warmupInfo[ msg.sender ].lock);
    }

    /**
        @notice redeem MEMO for Time
        @param _amount uint
        @param _trigger bool
     */
    function unstake( uint _amount, bool _trigger ) external {
        if ( _trigger ) {
            rebase();
        }
        Memories.safeTransferFrom( msg.sender, address(this), _amount );
        Time.safeTransfer( msg.sender, _amount );
        emit LogUnstake(msg.sender, _amount);
    }

    /**
        @notice returns the MEMO index, which tracks rebase growth
        @return uint
     */
    function index() external view returns ( uint ) {
        return Memories.index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if( epoch.endTime <= uint32(block.timestamp) ) {

            Memories.rebase( epoch.distribute, epoch.number );

            epoch.endTime = epoch.endTime.add32( epoch.length );
            epoch.number++;
            
            if ( address(distributor) != address(0) ) {
                distributor.distribute();
            }

            uint balance = contractBalance();
            uint staked = Memories.circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub( staked );
            }
            emit LogRebase(epoch.distribute);
        }
    }

    /**
        @notice returns contract Time holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return Time.balanceOf( address(this) ).add( totalBonus );
    }

    enum CONTRACTS { DISTRIBUTOR, WARMUP }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract( CONTRACTS _contract, address _address ) external onlyOwner {
        if( _contract == CONTRACTS.DISTRIBUTOR ) { // 0
            distributor = IDistributor(_address);
        } else if ( _contract == CONTRACTS.WARMUP ) { // 1
            require( address(warmupContract) == address( 0 ), "Warmup cannot be set more than once" );
            warmupContract = IWarmup(_address);
        }
        emit LogSetContract(_contract, _address);
    }
    
    /**
     * @notice set warmup period in epoch's numbers for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint _warmupPeriod ) external onlyOwner {
        warmupPeriod = _warmupPeriod;
        emit LogWarmupPeriod(_warmupPeriod);
    }
}