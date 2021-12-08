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
    uint256 public claimTimeout;
    uint256 public claimDailyLimit;

    // current rest of daily limit available to claim
    uint256 public currentClaimDailyLimit;
    uint256 public lastYMD;

    mapping(address => uint256) public walletNonce;

    /*
                        
        availableForRequests = deliveryToken.balanceOf() - lockedForRequests

    */
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
        uint256 index;      // index at walletRequests
        bool isDeactivated; // false by default means request is actual (not deactivated by admin)
    }

    // raw request list
    Request[] public requests;
    // wallet -> request ids list, to reduce memory usage needs to move (clear from requests) finished id to finishedRequests
    mapping(address => uint256[]) walletRequests;

    // request -> wallet, only added link for getting wallet by requestId
    mapping(uint256 => address) requestWallet;

    // wallet -> finished request ids list
    mapping(address => uint256[]) walletFinishedRequests;

    event ClaimRequested(address indexed wallet, uint256 indexed reauestId);
    event Claimed(address indexed wallet, uint256 amount);

    function initialize(
        address _signatureWallet,
        address _deliveryToken,
        address _deliveryAdmin,
        uint256 _claimTimeout,
        uint256 _claimDailyLimit
    ) public virtual initializer {
        __Ownable_init();
        transferOwnership(_deliveryAdmin);
        signatureWallet = _signatureWallet;
        claimTimeout = _claimTimeout;
        claimDailyLimit = _claimDailyLimit;
        deliveryToken = IERC20Upgradeable(_deliveryToken);
    }

    function getWalletNonce() public view returns (uint256) {
        return walletNonce[msg.sender];
    }

    function request(
        address wallet,
        uint256 amount,
        uint256 nonce,
        bytes memory sig
    ) public {
        require(wallet == msg.sender, "incorrect sender");
        require(amount <= availableForRequests(), "insufficient reserves");
        // check sign
        bytes32 message = _prefixed(keccak256(abi.encodePacked(wallet, amount, nonce, this)));

        require(
            _recoverSigner(message, sig) == signatureWallet && walletNonce[msg.sender] < nonce,
            "incorrect signature"
        );

        walletNonce[wallet] = nonce;

        // set requests
        requests.push(
            Request({
                claimfromYMD: timestampToYMD(block.timestamp + claimTimeout),
                requestedAmount: amount,
                paidAmount: 0,
                index: walletRequests[msg.sender].length, // save index
                isDeactivated: false
            })
        );

        lockedForRequests += amount;

        // save request id by wallet
        walletRequests[msg.sender].push(requests.length - 1); // Request.index
        // link request to wallet
        requestWallet[requests.length - 1] = msg.sender;
        emit ClaimRequested(msg.sender, requests.length - 1);
    }

    function claim() public {
        _updateLimits();
        (uint256 available, uint256[] memory requestIds) = getAvailableToClaim();
        require(available > 0, "nothing to claim");
        require(available <= currentClaimDailyLimit, "Limit exceeded");

        currentClaimDailyLimit -= available;

        _claimRequests(available, requestIds);
        lockedForRequests -= available;
        deliveryToken.safeTransfer(msg.sender, available);
        emit Claimed(msg.sender, available);
    }

    /***************************** internal ****************************/

    /**
     * @dev update daily limits: reset on new day
     */
    function _updateLimits() internal {
        // set next day limits
        if (lastYMD < timestampToYMD(block.timestamp)) {
            currentClaimDailyLimit = claimDailyLimit;
            lastYMD = timestampToYMD(block.timestamp);
        }
    }

    function _claimRequests(uint256 available, uint256[] memory requestIds) internal {
        require(requestIds.length > 0, "no requests for claiming");
        // go by requests and claim available amount one by one
        for (uint256 i = 0; i < requestIds.length; i++) {
            require(requests[requestIds[i]].claimfromYMD <= timestampToYMD(block.timestamp), "incorrect claim");
            if (available <= 0) return;
            // claim available
            uint256 restOfPayment = requests[requestIds[i]].requestedAmount - requests[requestIds[i]].paidAmount;

            // reduce available by rest of payment
            if (available >= restOfPayment) {
                requests[requestIds[i]].paidAmount += restOfPayment;
                available -= restOfPayment;
            } else {
                requests[requestIds[i]].paidAmount += available;
                available = 0;
            }
            // request filled -> add to finished requests and remove from wallet requests
            if (requests[requestIds[i]].requestedAmount == requests[requestIds[i]].paidAmount) {
                walletFinishedRequests[msg.sender].push(requestIds[i]);
                // remove completed reuqest id
                walletRequests[msg.sender][requests[requestIds[i]].index] = walletRequests[msg.sender][
                    walletRequests[msg.sender].length - 1
                ];
                walletRequests[msg.sender].pop();
            }
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
    }

    /**
     * @dev owner withdraw amount from available amount
     * @param amount for withdraw of "deliveryToken"
     */
    function withdraw(uint256 amount) public onlyOwner {
        require(amount > 0 && amount <= availableForRequests(), "amount must be > 0 and <= available");
        deliveryToken.safeTransfer(msg.sender, amount);
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

    function setSignatureWallet(address _signatureWallet) public onlyOwner {
        require(signatureWallet != _signatureWallet, "not changed");
        signatureWallet = _signatureWallet;
    }

    /**
     * @dev Owner can transfer out any accidentally sent ERC20 tokens
     * @param tokenAddress Address of ERC-20 token to transfer
     * @param beneficiary Address to transfer to
     * @param amount of tokens to transfer
     */
    function transferAnyERC20Token(
        address tokenAddress,
        address beneficiary,
        uint256 amount
    ) public nonReentrant onlyOwner returns (bool success) {
        require(tokenAddress != address(0), "address 0!");
        require(tokenAddress != address(deliveryToken), "not deliveryToken");

        return IERC20Upgradeable(tokenAddress).transfer(beneficiary, amount);
    }

    /**
     * @dev admin remove request list
     * @param requestIds - list of gequests to remove
     */
    function removeRequest(uint256[] memory requestIds) public onlyOwner {
        uint256 freedAmount;
        address wallet;
        for (uint256 i = 0; i < requestIds.length; i++) {
            // if request is active and not completly paid 
            Request storage req = requests[requestIds[i]];
            if (!req.isDeactivated && (req.requestedAmount - req.paidAmount) > 0) {
                // save freed amount
                freedAmount += (req.requestedAmount - req.paidAmount);
                // power off request
                req.isDeactivated = true;

                // get wallet 
                wallet = requestWallet[requestIds[i]];
                //finish request
                walletFinishedRequests[wallet].push(requestIds[i]);
                // remove completed reuqest id
                walletRequests[wallet][req.index] = walletRequests[wallet][
                    walletRequests[wallet].length - 1
                ];
                walletRequests[wallet].pop();
            }
        }
        // resurect limit
        currentClaimDailyLimit += freedAmount;
        // reduce requested amount
        lockedForRequests += freedAmount;
    }

    /*************************** view ************************************/
    function getClaimDailyLimit() public view returns (uint256 limit) {
        if (lastYMD < timestampToYMD(block.timestamp)) {
            limit = claimDailyLimit; // if not updated this day
        } else {
            limit = currentClaimDailyLimit; // if updated
        }
    }

    function totalSupply() public view returns (uint256 supply) {
        supply = deliveryToken.balanceOf(address(this));
    }

    function availableForRequests() public view returns (uint256 available) {
        available = totalSupply() - lockedForRequests;
    }

    function getFinishedRequests(address wallet) public view returns (uint256[] memory requestIds) {
        // fillup returning requestIds
        if (walletFinishedRequests[wallet].length > 0) {
            uint256[] memory _tempList = new uint256[](walletFinishedRequests[wallet].length);
            for (uint256 i = 0; i < walletFinishedRequests[wallet].length; i++) {                
                _tempList[i] = walletFinishedRequests[wallet][i];
            }
            requestIds = _tempList;
        }
    }

    function getRemainderOfRequests() public view returns (uint256 remainder, uint256[] memory requestIds) {
        uint256 count;
        for (uint256 i = 0; i < walletRequests[msg.sender].length; i++) {
            Request memory _req = requests[walletRequests[msg.sender][i]];
            // add remainder amount for all requests
            remainder += _req.requestedAmount - _req.paidAmount;
            // count requests
            count++;
        }
        // fillup returning requestIds
        if (count > 0) {
            uint256[] memory _tempList = new uint256[](count);
            for (uint256 i = 0; i < walletRequests[msg.sender].length; i++) {
                count--;
                _tempList[count] = walletRequests[msg.sender][i];
            }
            requestIds = _tempList;
        }
    }

    function getAvailableToClaim() public view returns (uint256 available, uint256[] memory requestIds) {
        uint256 count;
        for (uint256 i = 0; i < walletRequests[msg.sender].length; i++) {
            Request memory _req = requests[walletRequests[msg.sender][i]];
            if (
                available < getClaimDailyLimit() &&
                !_req.isDeactivated &&
                (_req.requestedAmount - _req.paidAmount) > 0 &&
                _req.claimfromYMD <= timestampToYMD(block.timestamp)
            ) {
                // add available amount according daily available for requests
                available += (available + (_req.requestedAmount - _req.paidAmount) <= getClaimDailyLimit())
                    ? (_req.requestedAmount - _req.paidAmount)
                    : getClaimDailyLimit();
                // count requests
                count++;
            }
        }
        // fillup returning requestIds
        if (count > 0) {
            uint256[] memory _tempList = new uint256[](count);
            for (uint256 i = 0; i < walletRequests[msg.sender].length; i++) {
                Request memory _req = requests[walletRequests[msg.sender][i]];
                if (
                    available < getClaimDailyLimit() &&
                    !_req.isDeactivated &&
                    (_req.requestedAmount - _req.paidAmount) > 0 &&
                    _req.claimfromYMD >= timestampToYMD(block.timestamp)
                ) {
                    count--;
                    // save request id
                    _tempList[count] = walletRequests[msg.sender][i];
                }
            }
            requestIds = _tempList;
        }
    }
}
