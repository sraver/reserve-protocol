// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../libraries/Fixed.sol";
import "./ERC20Mock.sol";
import "../assets/concentrator/IaCRV.sol";

contract aCRVMock is ERC20Mock {
    uint256 private underlying;

    constructor(
        string memory name,
        string memory symbol
    ) ERC20Mock(name, symbol) {}

    function setUnderlying(uint256 amount) external {
        underlying = amount;
    }

    function totalUnderlying() external view returns (uint256) {
        return underlying;
    }

    function harvest(address _recipient, uint256 _minimumOut) external returns (uint256) {
        return 0;
    }
}
