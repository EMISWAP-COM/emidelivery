//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./oraclesign.sol";

/**
 * @dev EmiDelivery contract recevs signed user's requests and allows to claim requested tokens after XX time passed
 * admin set: lock time period, can reject requesdt, deposite and withdraw tokens
 */
contract emidelivery is ReentrancyGuardUpgradeable, OwnableUpgradeable, OracleSign {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public deliveryToken;
    address public signatureWallet;
    address public deliveryAdmin;
    uint256 public claimTimeout;

    mapping(address => uint256) public walletNonce;

    /*
                        / availableForRequests
        totalSupply = = 
                        \ lockedForRequests      
    */
    // value available for new requests
    uint256 public availableForRequests;
    // value locked by existing unclaimed requests values
    uint256 public lockedForRequests;

    function initialize(
        address _signatureWallet,
        address _deliveryToken,
        address _deliveryAdmin,
        uint256 _claimTimeout
    ) public virtual initializer {
        __Ownable_init();
        transferOwnership(_deliveryAdmin);
        signatureWallet = _signatureWallet;
        claimTimeout = _claimTimeout;
        deliveryToken = IERC20Upgradeable(_deliveryToken);
    }

    function request(address wallet, uint256 nonce, uint256 amount, bytes memory sig) public {
        require(wallet == msg.sender, "incorrect sender");
        // check sign
        bytes32 message =
        _prefixed(
            keccak256(abi.encodePacked(wallet, amount, nonce, this))
        );

        require(
            _recoverSigner(message, sig) == signatureWallet &&
            walletNonce[msg.sender] < nonce,
            "incorrect signature"
        );

        walletNonce[msg.sender] = nonce;
        // set request 
    }

    /****************************** admin ******************************/

    /**
     * @dev owner deposit amount for delivery tokens by requests
     * @param amount deposited value of "deliveryToken"
     */

    function deposite(uint256 amount) public onlyOwner {
        require(amount>0, "amount must be > 0");
        deliveryToken.safeTransferFrom(msg.sender, address(this), amount);
        availableForRequests += amount;
    }

    /**
     * @dev owner withdraw amount from available amount
     * @param amount for withdraw of "deliveryToken"
     */
    function withdraw(uint256 amount) public onlyOwner {
        require(amount>0 && amount <= availableForRequests, "amount must be > 0 and <= available");
        deliveryToken.safeTransfer(msg.sender, amount);
        availableForRequests -= amount;
    }

    function setNewTimeOut(uint256 newClaimTimeout) public onlyOwner {
        claimTimeout = newClaimTimeout;
    }

    /*************************** view ************************************/
    function totalSupply() public view returns(uint256 supply) {
        supply = availableForRequests + lockedForRequests;
    }
}
