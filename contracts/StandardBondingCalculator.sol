// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
import './libraries/FullMath.sol';
import './libraries/Babylonian.sol';
import './libraries/BitMath.sol';
import './libraries/FixedPoint.sol';
import './libraries/LowGasSafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2.sol';

interface IBondingCalculator {
  function valuation( address pair_, uint amount_ ) external view returns ( uint _value );
}

contract TimeBondingCalculator is IBondingCalculator {

    using FixedPoint for *;
    using LowGasSafeMath for uint;
    using LowGasSafeMath for uint112;

    IERC20 public immutable Time;

    constructor( address _Time ) {
        require( _Time != address(0) );
        Time = IERC20(_Time);
    }

    function getKValue( address _pair ) public view returns( uint k_ ) {
        uint token0 = IERC20( IUniswapV2Pair( _pair ).token0() ).decimals();
        uint token1 = IERC20( IUniswapV2Pair( _pair ).token1() ).decimals();
        uint pairDecimals = IERC20( _pair ).decimals();

        (uint reserve0, uint reserve1, ) = IUniswapV2Pair( _pair ).getReserves();
        if (token0.add(token1) <  pairDecimals)
        {
            uint decimals = pairDecimals.sub(token0.add(token1));
            k_ = reserve0.mul(reserve1).mul( 10 ** decimals );
        }
        else {
            uint decimals = token0.add(token1).sub(pairDecimals);
            k_ = reserve0.mul(reserve1).div( 10 ** decimals );
        }
        
    }

    function getTotalValue( address _pair ) public view returns ( uint _value ) {
        _value = getKValue( _pair ).sqrrt().mul(2);
    }

    function valuation( address _pair, uint amount_ ) external view override returns ( uint _value ) {
        uint totalValue = getTotalValue( _pair );
        uint totalSupply = IUniswapV2Pair( _pair ).totalSupply();

        _value = totalValue.mul( FixedPoint.fraction( amount_, totalSupply ).decode112with18() ).div( 1e18 );
    }

    function markdown( address _pair ) external view returns ( uint ) {
        ( uint reserve0, uint reserve1, ) = IUniswapV2Pair( _pair ).getReserves();

        uint reserve;
        if ( IUniswapV2Pair( _pair ).token0() == address(Time) ) {
            reserve = reserve1;
        } else {
            require(IUniswapV2Pair( _pair ).token1() == address(Time), "not a Time lp pair");
            reserve = reserve0;
        }
        return reserve.mul( 2 * ( 10 ** Time.decimals() ) ).div( getTotalValue( _pair ) );
    }
}
