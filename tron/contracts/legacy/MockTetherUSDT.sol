// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockTetherUSDT
/// @notice Energy-equivalent stand-in for TRON USDT, used because the Nile faucet
///         did not dispense test USDT.
///
/// @dev This is NOT a byte-identical redeployment of Tether's contract, which is
///      Solidity 0.4.17 and will not compile here. It is a 0.8.x replica of the
///      exact storage-access pattern of `TetherToken.transfer`, which is what
///      determines Energy cost:
///
///        reads : paused, isBlackListed[from], deprecated, basisPointsRate,
///                maximumFee, balances[from], balances[to]
///        writes: balances[from], balances[to]
///
///      It also reproduces Tether's non-standard signature: `transfer` returns
///      NOTHING, which is why the vault must use SafeERC20 on both chains.
///
///      Measured numbers from this token are cross-checked against a simulated
///      transfer on the real Nile USDT contract in the report.
contract MockTetherUSDT {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;

    address public owner;
    bool public deprecated;
    bool public paused;
    uint256 public basisPointsRate;
    uint256 public maximumFee;
    uint256 public totalSupply;

    mapping(address => uint256) public balances;
    mapping(address => bool) public isBlackListed;
    mapping(address => mapping(address => uint256)) public allowed;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        owner = msg.sender;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }

    function mint(uint256 amount) external {
        require(msg.sender == owner, "not owner");
        balances[owner] += amount;
        totalSupply += amount;
        emit Transfer(address(0), owner, amount);
    }

    /// @dev No return value, exactly like Tether.
    function transfer(address _to, uint256 _value) external {
        require(!paused, "paused");
        require(!isBlackListed[msg.sender], "blacklisted");
        require(!deprecated, "deprecated");

        uint256 fee = (_value * basisPointsRate) / 10000;
        if (fee > maximumFee) fee = maximumFee;
        uint256 sendAmount = _value - fee;

        balances[msg.sender] -= _value;
        balances[_to] += sendAmount;
        if (fee > 0) {
            balances[owner] += fee;
            emit Transfer(msg.sender, owner, fee);
        }
        emit Transfer(msg.sender, _to, sendAmount);
    }

    function approve(address _spender, uint256 _value) external {
        allowed[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
    }

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return allowed[_owner][_spender];
    }

    function transferFrom(address _from, address _to, uint256 _value) external {
        require(!paused, "paused");
        require(!isBlackListed[_from], "blacklisted");
        allowed[_from][msg.sender] -= _value;
        balances[_from] -= _value;
        balances[_to] += _value;
        emit Transfer(_from, _to, _value);
    }
}
