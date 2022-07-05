// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/Babylonian.sol';
import 'https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol';
import 'https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.3.0/contracts/token/ERC20/SafeERC20.sol';

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IStaking {
    function stake(uint256 amount) external;
}

/// @title SimpleZap Contract
/// @notice A zap function to provide LP stakers to stake with single asset
/// @author Minato M.
contract SimpleZap {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // State Variables
    IUniswapV2Router02 public immutable router;
    IStaking public masterChef;
    address public immutable WETH;
    uint256 public constant minimumAmount = 1000;

    constructor(address _router, address _masterChef, address _WETH) public {
        router = IUniswapV2Router02(_router);
        masterChef = IStaking(_masterChef);
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH);
    }

    function zapInETH (uint256 tokenAmountOutMin, address want) external payable {
        require(msg.value >= minimumAmount, 'SimpleZap: Insignificant input amount');

        IWETH(WETH).deposit{value: msg.value}();

        _swapAndStake(tokenAmountOutMin, want, WETH);
    }

    function zapIn (uint256 tokenAmountOutMin, address want, address tokenIn, uint256 tokenInAmount) external {
        require(tokenInAmount >= minimumAmount, 'SimpleZap: Insignificant input amount');
        require(IERC20(tokenIn).allowance(msg.sender, address(this)) >= tokenInAmount, 'SimpleZap: Input token is not approved');

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), tokenInAmount);

        _swapAndStake(tokenAmountOutMin, want, tokenIn);
    }

    /// @notice - swap half of token and add liquidity as LP to main staking contract
    /// @param tokenAmountOutMin - minimum amount to be swapped out
    /// @param want - uniswap pair address
    /// @param tokenIn - base token to be zapped
    function _swapAndStake(uint256 tokenAmountOutMin, address want, address tokenIn) private {
        IUniswapV2Pair pair = IUniswapV2Pair(want);
        (uint256 reserveA, uint256 reserveB,) = pair.getReserves();
        require(reserveA > minimumAmount && reserveB > minimumAmount, 'SimpleZap: Liquidity pair reserves too low');

        bool isInputA = pair.token0() == tokenIn;
        require(isInputA || pair.token1() == tokenIn, 'SimpleZap: Input token not present in liqudity pair');

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = isInputA ? pair.token1() : pair.token0();

        uint256 fullInvestment = IERC20(tokenIn).balanceOf(address(this));
        uint256 swapAmountIn;
        if (isInputA) {
            swapAmountIn = _getSwapAmount(fullInvestment, reserveA, reserveB);
        } else {
            swapAmountIn = _getSwapAmount(fullInvestment, reserveB, reserveA);
        }

        _approveTokenIfNeeded(path[0], address(router));
        uint256[] memory swapedAmounts = router
            .swapExactTokensForTokens(swapAmountIn, tokenAmountOutMin, path, address(this), block.timestamp);

        _approveTokenIfNeeded(path[1], address(router));
        (,, uint256 amountLiquidity) = router
            .addLiquidity(path[0], path[1], fullInvestment.sub(swapedAmounts[0]), swapedAmounts[1], 1, 1, address(this), block.timestamp);

        masterChef.stake(amountLiquidity);
    }

    function _getSwapAmount(uint256 investmentA, uint256 reserveA, uint256 reserveB) private view returns (uint256 swapAmount) {
        uint256 halfInvestment = investmentA / 2;
        uint256 nominator = router.getAmountOut(halfInvestment, reserveA, reserveB);
        uint256 denominator = router.quote(halfInvestment, reserveA.add(halfInvestment), reserveB.sub(nominator));
        swapAmount = investmentA.sub(Babylonian.sqrt(halfInvestment * halfInvestment * nominator / denominator));
    }

    function _approveTokenIfNeeded(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).safeApprove(spender, uint256(~0));
        }
    }
}