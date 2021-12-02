//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./helpers/timeHelper.sol";
import "./oraclesign.sol";

/**
 * @dev EmiDelivery contract recevs signed user's requests and allows to claim requested tokens after XX time passed
 * admin set: lock time period, can reject requesdt, deposite and withdraw tokens
 */
contract emidelivery is ReentrancyGuardUpgradeable, OwnableUpgradeable, OracleSign, timeHelper {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public deliveryToken;
    // settings values
    address public signatureWallet;
    address public deliveryAdmin;
    uint256 public claimTimeout;
    uint256 public claimDailyLimit;

    // current rest of daily limit available to claim
    uint256 public currentClaimDailyLimit;
    uint256 public lastYMD;

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

    /*
        request record structure
        "rest request payment" = requestedAmount - paidAmount
    */
    struct Request {
        uint256 claimfromYMD; // date for start claiming
        uint256 requestedAmount;
        uint256 paidAmount;
        bool isDeactivated; // false by default means request is actual (not deactivated by admin)
    }

    // raw request list
    Request[] public requests;
    // wallet -> request ids list, to reduce memory usage needs to move (clear from requests) finished id to finishedRequests
    mapping(address => uint256[]) walletRequests;

    // wallet -> finished request ids list
    mapping(address => uint256[]) walletFinishedRequests;

    event claimRequested(address wallet, uint256 reauestId);

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

    function request(
        address wallet,
        uint256 nonce,
        uint256 amount,
        bytes memory sig
    ) public {
        require(wallet == msg.sender, "incorrect sender");
        // check sign
        bytes32 message = _prefixed(keccak256(abi.encodePacked(wallet, amount, nonce, this)));

        require(
            _recoverSigner(message, sig) == signatureWallet && walletNonce[msg.sender] < nonce,
            "incorrect signature"
        );

        walletNonce[msg.sender] = nonce;

        // set requests
        requests.push(
            Request({
                claimfromYMD: timestampToYMD(block.timestamp + claimTimeout),
                requestedAmount: amount,
                paidAmount: 0,
                isDeactivated: false
            })
        );

        // save request id
        walletRequests[msg.sender].push(requests.length - 1);
        emit claimRequested(msg.sender, requests.length - 1);
    }

    function claim(uint256 reuqest) public {}

    /***************************** internal ****************************/

    /**
     * @dev update daily limits: reset on new day, reduce claimlimit on claim
     * @param claimAmount amount reduces current day limit, can be 0 - use to reset lastYMD and limit
     */
    function _updateLimits(uint256 claimAmount) internal {
        // set next day limits
        if (lastYMD < timestampToYMD(block.timestamp)) {
            currentClaimDailyLimit = claimDailyLimit;
            lastYMD = timestampToYMD(block.timestamp);
        }
        require(claimAmount <= currentClaimDailyLimit, "Limit exceeded");
        if (claimAmount > 0) {
            currentClaimDailyLimit -= claimAmount;
        }
    }

    /****************************** admin ******************************/

    /**
     * @dev owner deposit amount for delivery tokens by requests
     * @param amount deposited value of "deliveryToken"
     */

    function deposite(uint256 amount) public onlyOwner {
        require(amount > 0, "amount must be > 0");
        deliveryToken.safeTransferFrom(msg.sender, address(this), amount);
        availableForRequests += amount;
    }

    /**
     * @dev owner withdraw amount from available amount
     * @param amount for withdraw of "deliveryToken"
     */
    function withdraw(uint256 amount) public onlyOwner {
        require(amount > 0 && amount <= availableForRequests, "amount must be > 0 and <= available");
        deliveryToken.safeTransfer(msg.sender, amount);
        availableForRequests -= amount;
    }

    function setNewTimeOut(uint256 newClaimTimeout) public onlyOwner {
        claimTimeout = newClaimTimeout;
    }

    /**
     * @dev set new claim daily limit, changes affect next day!
     */
    function setNewClaimDailyLimit(uint256 newclaimDailyLimit) public onlyOwner {
        claimDailyLimit = newclaimDailyLimit;
    }

    /*************************** view ************************************/
    function totalSupply() public view returns (uint256 supply) {
        supply = availableForRequests + lockedForRequests;
    }
}
