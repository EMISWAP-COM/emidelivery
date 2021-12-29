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
    // allow only one unclaimed request for the wallet, make new request only after fully claimed previous
    bool public isOneRequest;

    /**
     * working day shift feature, to make YMD shifted of block.timestamp
     *
     * cases:
     *   Paris local time from block.timestamp (GMT) + 1 hour
     *   localShift = true
     *   positiveShift = 1 * 60 * 60
     *
     *   NewYork local time from block.timestamp (GMT) - 5 hour
     *   localShift = false
     *   positiveShift = 5 * 60 * 60
     *
     *   Tokyo local time from block.timestamp (GMT) + 9 hour
     *   localShift = true
     *   positiveShift = 9 * 60 * 60
     */
    bool public positiveShift;
    uint256 public localShift;

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
        uint256 index; // index at walletRequests
        bool isDeactivated; // false by default means request is actual (not deactivated by admin)
    }

    // raw request list
    Request[] public requests;
    // wallet -> request ids list, to reduce memory usage needs to move (clear from requests) finished id to finishedRequests
    mapping(address => uint256[]) public walletRequests;

    // request -> wallet, only added link for getting wallet by requestId
    mapping(uint256 => address) public requestWallet;

    // wallet -> finished request ids list
    mapping(address => uint256[]) public walletFinishedRequests;

    // operator - activated
    mapping(address => bool) public operators;

    event ClaimRequested(address indexed wallet, uint256 indexed requestId);
    event Claimed(address indexed wallet, uint256 amount);

    modifier onlyOperator() {
        require(operators[msg.sender], "Only operator allowed");
        _;
    }

    function initialize(
        address _signatureWallet,
        address _deliveryToken,
        address _deliveryAdmin,
        uint256 _claimTimeout,
        uint256 _claimDailyLimit,
        bool _isOneRequest,
        uint256 _localShift,
        bool _positiveShift
    ) public virtual initializer {
        __Ownable_init();
        transferOwnership(_deliveryAdmin);
        signatureWallet = _signatureWallet;
        claimTimeout = _claimTimeout;
        claimDailyLimit = _claimDailyLimit;
        deliveryToken = IERC20Upgradeable(_deliveryToken);
        isOneRequest = _isOneRequest;
        operators[_deliveryAdmin] = true;
        localShift = _localShift;
        positiveShift = _positiveShift;
    }

    function getWalletNonce() public view returns (uint256) {
        return walletNonce[msg.sender];
    }

    /*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*/
    /*@@@@@@@@@@@@@@   ONLY FOR TESTING !!!   @@@@ REMOVE FOR PRODUCTION @@@@@@@@@@@@@@@@@@@@@@@*/
    /*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*/
    function requestUnsigned(
        address wallet,
        uint256 amount,
        uint256 nonce,
        bytes memory sig
    ) public onlyOperator {
        require(wallet == msg.sender, "incorrect sender");
        require(amount <= availableForRequests(), "insufficient reserves");
        if (isOneRequest) {
            (uint256 remainder, , , ) = getRemainderOfRequests();
            require(isOneRequest && remainder == 0, "unclaimed request exists");
        }

        walletNonce[wallet] = nonce;

        // set requests
        requests.push(
            Request({
                claimfromYMD: timestampToYMD(localTime() + claimTimeout),
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

    /*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*/
    /*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*/

    function request(
        address wallet,
        uint256 amount,
        uint256 nonce,
        bytes memory sig
    ) public {
        require(wallet == msg.sender, "incorrect sender");
        require(amount <= availableForRequests(), "insufficient reserves");
        if (isOneRequest) {
            (uint256 remainder, , , ) = getRemainderOfRequests();
            require(isOneRequest && remainder == 0, "unclaimed request exists");
        }
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
                claimfromYMD: timestampToYMD(localTime() + claimTimeout),
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
        if (lastYMD < timestampToYMD(localTime())) {
            currentClaimDailyLimit = claimDailyLimit;
            lastYMD = timestampToYMD(localTime());
        }
    }

    function _claimRequests(uint256 available, uint256[] memory requestIds) internal {
        require(requestIds.length > 0, "no requests for claiming");
        // go by requests and claim available amount one by one
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 reqId = requestIds[i];
            require(requests[reqId].claimfromYMD <= timestampToYMD(localTime()), "incorrect claim");
            if (available <= 0) return;
            // claim available
            uint256 restOfPayment = requests[reqId].requestedAmount - requests[reqId].paidAmount;

            // reduce available by rest of payment
            if (available >= restOfPayment) {
                requests[reqId].paidAmount += restOfPayment;
                available -= restOfPayment;
            } else {
                requests[reqId].paidAmount += available;
                available = 0;
            }
            // request filled -> add to finished requests and remove from wallet requests
            if (requests[reqId].requestedAmount == requests[reqId].paidAmount) {
                walletFinishedRequests[msg.sender].push(reqId);
                uint256 shiftedReqId = walletRequests[msg.sender][walletRequests[msg.sender].length - 1];
                // remove completed reuqest id
                walletRequests[msg.sender][requests[reqId].index] = shiftedReqId;

                // set index of shifted request to finished reqId
                requests[shiftedReqId].index = requests[reqId].index;

                // remove freed record
                walletRequests[msg.sender].pop();
            }
        }
    }

    /****************************** admin ******************************/
    function setLocalTimeShift(uint256 newLocalShift, bool newPositiveShift)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        positiveShift = newPositiveShift;
        localShift = newLocalShift;
    }

    function setOperator(address newOperator, bool isActive)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        operators[newOperator] = isActive;
    }

    function setisOneRequest(bool newisOneRequest)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        require(isOneRequest != newisOneRequest, "nothing to change");
        isOneRequest = newisOneRequest;
    }

    /**
     * @dev owner deposit amount for delivery tokens by requests
     * @param amount deposited value of "deliveryToken"
     */

    function deposite(uint256 amount)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        require(amount > 0, "amount must be > 0");
        deliveryToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev owner withdraw amount from available amount
     * @param amount for withdraw of "deliveryToken"
     */
    function withdraw(uint256 amount)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        require(amount > 0 && amount <= availableForRequests(), "amount must be > 0 and <= available");
        deliveryToken.safeTransfer(msg.sender, amount);
    }

    function setNewTimeOut(uint256 newClaimTimeout)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        claimTimeout = newClaimTimeout;
    }

    /**
     * @dev set new claim daily limit, changes affect next day!
     */
    function setNewClaimDailyLimit(uint256 newclaimDailyLimit)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
        claimDailyLimit = newclaimDailyLimit;
    }

    function setSignatureWallet(address _signatureWallet)
        public
        /*removed only fo testing!!! onlyOwner*/
        onlyOperator
    {
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
    )
        public
        nonReentrant
        /* onlyOwner */
        onlyOperator
        returns (bool success)
    {
        require(tokenAddress != address(0), "address 0!");
        require(tokenAddress != address(deliveryToken), "not deliveryToken");
        return IERC20Upgradeable(tokenAddress).transfer(beneficiary, amount);
    }

    /**
     * @dev only "operator" remove request list
     * @param requestIds - list of gequests to remove
     */
    function removeRequest(uint256[] memory requestIds) public onlyOperator {
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
                walletRequests[wallet][req.index] = walletRequests[wallet][walletRequests[wallet].length - 1];
                walletRequests[wallet].pop();
            }
        }
        // resurect limit
        currentClaimDailyLimit += freedAmount;
        // reduce requested amount
        lockedForRequests += freedAmount;
    }

    /*************************** view ************************************/
    /**
     * @dev get block.timestamp corrected with local settings shift
     */
    function localTime() public view returns (uint256 localTimeStamp) {
        return positiveShift ? block.timestamp + localShift : block.timestamp - localShift;
    }

    /**
     * @dev get today starting timestamp and tomorrow starting timestamp
     */
    function getDatesStarts() public view returns (uint256 todayStart, uint256 tomorrowStart) {
        return (
            YMDToTimestamp(timestampToYMD(localTime())),
            YMDToTimestamp(timestampToYMD(localTime())) + 24 * 60 * 60
        );
    }

    function getClaimDailyLimit() public view returns (uint256 limit) {
        if (lastYMD < timestampToYMD(localTime())) {
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

    /**
     * @dev get remainder for actual requests
     * @return remainderTotal - total reuqested amount, not respected day limits
     * @return remainderPreparedForClaim - total reuqested amount, ready to claim at this day, not respected day limits
     * @return requestIds - list of actual request IDs
     * @return veryFirstRequestDate very first request claim-ready day from actual requests
     */
    function getRemainderOfRequests()
        public
        view
        returns (
            uint256 remainderTotal,
            uint256 remainderPreparedForClaim,
            uint256[] memory requestIds,
            uint256 veryFirstRequestDate
        )
    {
        (remainderTotal, remainderPreparedForClaim, requestIds, veryFirstRequestDate) = getRemainderOfRequestsbyWallet(
            msg.sender
        );
    }

    /**
     * @dev get remainder for actual requests by passed wallet
     * @param wallet - wallet for getting data
     * @return remainderTotal - total reuqested amount, not respected day limits
     * @return remainderPreparedForClaim - total reuqested amount, ready to claim at this day, not respected day limits
     * @return requestIds - list of actual request IDs
     * @return veryFirstRequestDate very first request claim-ready day from actual requests
     */
    function getRemainderOfRequestsbyWallet(address wallet)
        public
        view
        returns (
            uint256 remainderTotal,
            uint256 remainderPreparedForClaim,
            uint256[] memory requestIds,
            uint256 veryFirstRequestDate
        )
    {
        uint256 count;
        for (uint256 i = 0; i < walletRequests[wallet].length; i++) {
            Request memory _req = requests[walletRequests[wallet][i]];
            // add remainderTotal amount for all requests
            remainderTotal += _req.requestedAmount - _req.paidAmount;
            if (veryFirstRequestDate == 0 || _req.claimfromYMD <= veryFirstRequestDate) {
                veryFirstRequestDate = _req.claimfromYMD;
            }
            // calc amounts prepared for claim not respected day limits
            if (_req.claimfromYMD <= timestampToYMD(localTime())) {
                remainderPreparedForClaim += _req.requestedAmount - _req.paidAmount;
            }
            // count requests
            count++;
        }
        // fillup returning requestIds
        if (count > 0) {
            uint256[] memory _tempList = new uint256[](count);
            for (uint256 i = 0; i < walletRequests[wallet].length; i++) {
                count--;
                _tempList[count] = walletRequests[wallet][i];
            }
            requestIds = _tempList;
        }
    }

    /**
     * @dev get available tokens to claim according claim date and day limits, so once requested available will shown after claim date
     * @return available - tokens amount for the sender wallet
     * @return requestIds - request ids for the sender wallet
     */
    function getAvailableToClaim() public view returns (uint256 available, uint256[] memory requestIds) {
        (available, requestIds) = getAvailableToClaimbyWallet(msg.sender);
    }

    /**
     * @dev get available tokens to claim according claim date and day limits by passed wallet, so once requested available will shown after claim date
     * @param wallet - wallet for getting data
     * @return available - tokens amount for the sender wallet
     * @return requestIds - request ids for the sender wallet
     */
    function getAvailableToClaimbyWallet(address wallet)
        public
        view
        returns (uint256 available, uint256[] memory requestIds)
    {
        uint256 count;
        for (uint256 i = 0; i < walletRequests[wallet].length; i++) {
            Request memory _req = requests[walletRequests[wallet][i]];
            if (
                available < getClaimDailyLimit() &&
                !_req.isDeactivated &&
                (_req.requestedAmount - _req.paidAmount) > 0 &&
                _req.claimfromYMD <= timestampToYMD(localTime())
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
            for (uint256 i = 0; i < walletRequests[wallet].length; i++) {
                Request memory _req = requests[walletRequests[wallet][i]];
                if (
                    available <= getClaimDailyLimit() &&
                    !_req.isDeactivated &&
                    (_req.requestedAmount - _req.paidAmount) > 0 &&
                    _req.claimfromYMD <= timestampToYMD(localTime())
                ) {
                    count--;
                    // save request id
                    _tempList[count] = walletRequests[wallet][i];
                    // only one request takes it all - quit
                    if (available == getClaimDailyLimit()) {
                        break;
                    }
                }
            }
            requestIds = _tempList;
        }
    }
}
