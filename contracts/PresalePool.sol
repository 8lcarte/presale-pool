pragma solidity ^0.4.15;

import "./Util.sol";
import "./QuotaTracker.sol";


interface ERC20 {
    function transfer(address _to, uint _value) returns (bool success);
    function balanceOf(address _owner) constant returns (uint balance);
}

/* makes fees payable per person, not sure i like this way*/
interface FeeManager {
    function create(uint _feesPerEther, address[] _recipients);
    function sendFees() payable;
    function distrbuteFees(address[] _recipients);
}

contract PresalePool {
    using QuotaTracker for QuotaTracker.Data;

/*Defining possible states of contract
*state is public
*/
    enum State { Open, Failed, Paid, Refund }
    State public state;
/*defining public admins as a subset of the address[] array
and public variables for contribution*/
    address[] public admins;

    uint public minContribution;
    uint public maxContribution;
    uint public maxPoolBalance;

/*defining participants as a subset of the address[] array*/
    address[] public participants;
/** not sure **/
    bool public restricted;
/* a participant has the following variables associated to it */
    struct ParticipantState {
        uint contribution;
        uint remaining;
        bool whitelisted;
        bool exists;
    }
    /*defining that addresses have a ParticipantState*/
    mapping (address => ParticipantState) public balances;
    /*Defining whole puool balances*/
    uint public poolContributionBalance;
    uint public poolRemainingBalance;
    /*adding a public address to show where the money will go*/
    address public presaleAddress;
    /**honestly not sure what this is**/
    address public refundSenderAddress;
    QuotaTracker.Data etherRefunds;
    bool public allowTokenClaiming;
    QuotaTracker.Data tokenDeposits;

    /*making public the tokenContract for whatever the token is interfaces with above*/
    ERC20 public tokenContract;

    /*calls the interface with FeeManger from above*/
    FeeManager public feeManager;
    uint public totalFees;
    uint public feesPerEther;

    /*calling out varaibles for various events*/
    event Deposit(
        address indexed _from,
        uint _value,
        uint _contributionTotal,
        uint _poolContributionBalance
    );
    event FeeInstalled(
        uint _percentage
    );
    event ExpectingRefund(
        address _senderAddress
    );
    event TokenAddressSet(
        address _tokenAddress,
        bool _allowTokenClaiming,
        uint _poolTokenBalance
    );
    event TokenTransfer(
        address indexed _to,
        uint _value,
        bool _succeeded,
        uint _poolTokenBalance
    );
    event Withdrawl(
        address indexed _to,
        uint _value,
        uint _remaining,
        uint _contribution,
        uint _poolContributionBalance
    );
    event ContributionSettingsChanged(
        uint _minContribution,
        uint _maxContribution,
        uint _maxPoolBalance
    );
    event ContributionAdjusted(
        address indexed _participant,
        uint _remaining,
        uint _contribution,
        uint _poolContributionBalance
    );
    event WhitelistEnabled();
    event WhitelistDisabled();
    event IncludedInWhitelist(
        address indexed _participant
    );
    event RemovedFromWhitelist(
        address indexed _participant
    );
    event StateChange(
        State _from,
        State _to
    );
    event AddAdmin(
        address _admin
    );
    /*defining admins must be the sender of a message for an OnlyAdmins call*/
    modifier onlyAdmins() {
        require(Util.contains(admins, msg.sender));
        _;
    }
    /*if you want a function to call only on a certain state, use onState*/
    modifier onState(State s) {
        require(state == s);
        _;
    }
    /*Only allow tokens to be claimed after state is paid*/
    modifier canClaimTokens() {
        require(state == State.Paid && allowTokenClaiming);
        _;
    }
    /*define variables for presale function*/
    function PresalePool(
        address _feeManager,
        uint _feesPerEther,
        uint _minContribution,
        uint _maxContribution,
        uint _maxPoolBalance,
        address[] _admins,
        bool _restricted
    /* add payable modifier*/
    ) payable
    {
        /*add sender to admins -- why do that?*/
        AddAdmin(msg.sender);
        admins.push(msg.sender);
        /*set variables equal to inputs */
        minContribution = _minContribution;
        maxContribution = _maxContribution;
        maxPoolBalance = _maxPoolBalance;
        /*call validateContributionSettings function */
        validateContributionSettings();
        ContributionSettingsChanged(minContribution, maxContribution, maxPoolBalance);
        
        restricted = _restricted;
        balances[msg.sender].whitelisted = true;

        for (uint i = 0; i < _admins.length; i++) {
            address admin = _admins[i];
            if (!Util.contains(admins, admin)) {
                AddAdmin(admin);
                admins.push(admin);
                balances[admin].whitelisted = true;
            }
        }

        feesPerEther = _feesPerEther;
        FeeInstalled(feesPerEther);
        if (feesPerEther > 0) {
            feeManager = FeeManager(_feeManager);
            // 50 % fee is excessive
            require(feesPerEther * 2 < 1 ether);
            feeManager.create(feesPerEther, admins);
        }

        if (msg.value > 0) {
            deposit();
        }
    }

    function () public payable onState(State.Refund) {
        require(msg.sender == refundSenderAddress);
    }

    function version() public pure returns (uint, uint, uint) {
        return (1, 0, 0);
    }

    function fail() external onlyAdmins onState(State.Open) {
        changeState(State.Failed);
    }

    function payToPresale(address _presaleAddress, uint minPoolBalance) external onlyAdmins onState(State.Open) {
        require(poolContributionBalance >= minPoolBalance);
        changeState(State.Paid);
        assert(this.balance >= poolContributionBalance);

        if (feesPerEther > 0) {
            totalFees = (poolContributionBalance * feesPerEther) / 1 ether;
        }
        poolRemainingBalance = this.balance - poolContributionBalance;

        require(
            _presaleAddress.call.value(poolContributionBalance - totalFees)()
        );
    }

    function expectRefund(address sender) payable external onlyAdmins {
        require(state == State.Paid || state == State.Refund);
        require(tokenDeposits.totalClaimed == 0);
        if (sender != refundSenderAddress) {
            refundSenderAddress = sender;
            ExpectingRefund(sender);
        }
        if (state == State.Paid) {
            changeState(State.Refund);
        }
    }

    function transferFees() public onState(State.Paid) {
        require(totalFees > 0);
        require(tokenDeposits.totalClaimed > 0);
        uint amount = totalFees;
        totalFees = 0;
        feeManager.sendFees.value(amount)();
    }

    function transferAndDistributeFees() external {
        transferFees();
        feeManager.distrbuteFees(admins);
    }

    function setToken(address tokenAddress, bool _allowTokenClaiming) external onlyAdmins {
        require(state == State.Paid || state == State.Open);
        require(tokenDeposits.totalClaimed == 0);
        allowTokenClaiming = _allowTokenClaiming;
        tokenContract = ERC20(tokenAddress);
        TokenAddressSet(
            tokenAddress,
            allowTokenClaiming,
            tokenContract.balanceOf(address(this))
        );
    }

    function deposit() payable public onState(State.Open) {
        require(msg.value > 0);
        require(included(msg.sender));

        uint newContribution;
        uint newRemaining;
        (newContribution, newRemaining) = getContribution(msg.sender, msg.value);
        // must respect the maxContribution and maxPoolBalance limits
        require(newRemaining == 0);

        ParticipantState storage balance = balances[msg.sender];
        poolContributionBalance = poolContributionBalance - balance.contribution + newContribution;
        (balance.contribution, balance.remaining) = (newContribution, newRemaining);

        if (!balance.exists) {
            balance.whitelisted = true;
            balance.exists = true;
            participants.push(msg.sender);
        }
        Deposit(msg.sender, msg.value, balance.contribution, poolContributionBalance);
    }

    function withdrawAll() external {
        ParticipantState storage balance = balances[msg.sender];
        uint total = balance.remaining;
        balance.remaining = 0;

        if (state == State.Open || state == State.Failed) {
            total += balance.contribution;
            poolContributionBalance -= balance.contribution;
            balance.contribution = 0;
        } else if (state == State.Refund) {
            uint share = etherRefunds.claimShare(
                msg.sender,
                this.balance - poolRemainingBalance,
                [balance.contribution, poolContributionBalance]
            );
            poolRemainingBalance -= total;
            total += share;
        } else {
            require(state == State.Paid);
        }

        Withdrawl(msg.sender, total, 0, 0, poolContributionBalance);
        require(
            msg.sender.call.value(total)()
        );
    }

    function withdraw(uint amount) external onState(State.Open) {
        ParticipantState storage balance = balances[msg.sender];
        uint total = balance.remaining + balance.contribution;
        require(total >= amount && amount >= balance.remaining);

        uint debit = amount - balance.remaining;
        balance.remaining = 0;
        if (debit > 0) {
            balance.contribution -= debit;
            poolContributionBalance -= debit;
            require(balance.contribution >= minContribution);
        }

        Withdrawl(
            msg.sender,
            amount,
            balance.remaining,
            balance.contribution,
            poolContributionBalance
        );
        require(
            msg.sender.call.value(amount)()
        );
    }

    function transferMyTokens() external canClaimTokens {
        uint tokenBalance = tokenContract.balanceOf(address(this));
        transferTokensToRecipient(msg.sender, tokenBalance);
    }

    function transferAllTokens() external canClaimTokens {
        uint tokenBalance = tokenContract.balanceOf(address(this));

        for (uint i = 0; i < participants.length; i++) {
            tokenBalance = transferTokensToRecipient(participants[i], tokenBalance);

            if (tokenBalance == 0) {
                break;
            }
        }
    }

    function transferTokensTo(address[] recipients) external canClaimTokens {
        uint tokenBalance = tokenContract.balanceOf(address(this));

        for (uint i = 0; i < recipients.length; i++) {
            tokenBalance = transferTokensToRecipient(recipients[i], tokenBalance);

            if (tokenBalance == 0) {
                break;
            }
        }
    }

    function modifyWhitelist(address[] toInclude, address[] toExclude) external onlyAdmins onState(State.Open) {
        if (!restricted) {
            WhitelistEnabled();
            restricted = true;
        }
        uint i = 0;

        for (i = 0; i < toExclude.length; i++) {
            address participant = toExclude[i];
            ParticipantState storage balance = balances[participant];

            if (balance.whitelisted) {
                balance.whitelisted = false;
                RemovedFromWhitelist(participant);

                if (balance.contribution > 0) {
                    poolContributionBalance -= balance.contribution;
                    balance.remaining += balance.contribution;
                    balance.contribution = 0;
                    ContributionAdjusted(
                        participant,
                        balance.remaining,
                        balance.contribution,
                        poolContributionBalance
                    );
                }
            }
        }

        for (i = 0; i < toInclude.length; i++) {
            includeInWhitelist(toInclude[i]);
        }
    }

    function removeWhitelist() external onlyAdmins onState(State.Open) {
        require(restricted);
        restricted = false;
        WhitelistDisabled();

        for (uint i = 0; i < participants.length; i++) {
            includeInWhitelist(participants[i]);
        }
    }

    function setContributionSettings(uint _minContribution, uint _maxContribution, uint _maxPoolBalance) external onlyAdmins onState(State.Open) {
        // we raised the minContribution threshold
        bool recompute = (minContribution < _minContribution);
        // we lowered the maxContribution threshold
        recompute = recompute || (maxContribution > _maxContribution);
        // we did not have a maxContribution threshold and now we do
        recompute = recompute || (maxContribution == 0 && _maxContribution > 0);
        // we want to make maxPoolBalance lower than the current pool balance
        recompute = recompute || (poolContributionBalance > _maxPoolBalance);

        minContribution = _minContribution;
        maxContribution = _maxContribution;
        maxPoolBalance = _maxPoolBalance;

        validateContributionSettings();
        ContributionSettingsChanged(minContribution, maxContribution, maxPoolBalance);

        if (recompute) {
            poolContributionBalance = 0;
            for (uint i = 0; i < participants.length; i++) {
                address participant = participants[i];
                ParticipantState storage balance = balances[participant];
                uint oldContribution = balance.contribution;
                (balance.contribution, balance.remaining) = getContribution(participant, 0);
                poolContributionBalance += balance.contribution;

                if (oldContribution != balance.contribution) {
                    ContributionAdjusted(
                        participant,
                        balance.remaining,
                        balance.contribution,
                        poolContributionBalance
                    );
                }
            }
        }
    }

    function getParticipantBalances() external constant returns(address[], uint[], uint[], bool[], bool[]) {
        uint[] memory contribution = new uint[](participants.length);
        uint[] memory remaining = new uint[](participants.length);
        bool[] memory whitelisted = new bool[](participants.length);
        bool[] memory exists = new bool[](participants.length);

        for (uint i = 0; i < participants.length; i++) {
            ParticipantState storage balance = balances[participants[i]];
            contribution[i] = balance.contribution;
            remaining[i] = balance.remaining;
            whitelisted[i] = balance.whitelisted;
            exists[i] = balance.exists;
        }

        return (participants, contribution, remaining, whitelisted, exists);
    }

    function includeInWhitelist(address participant) internal {
        ParticipantState storage balance = balances[participant];

        if (!balance.whitelisted) {
            balance.whitelisted = true;
            IncludedInWhitelist(participant);

            if (balance.remaining > 0) {
                (balance.contribution, balance.remaining) = getContribution(participant, 0);
                if (balance.contribution > 0) {
                    poolContributionBalance += balance.contribution;
                    ContributionAdjusted(
                        participant,
                        balance.remaining,
                        balance.contribution,
                        poolContributionBalance
                    );
                }
            }
        }
    }

    function changeState(State desiredState) internal {
        StateChange(state, desiredState);
        state = desiredState;
    }

    function transferTokensToRecipient(address recipient, uint tokenBalance) internal returns(uint) {
        ParticipantState storage balance = balances[recipient];
        uint share = tokenDeposits.claimShare(
            recipient,
            tokenBalance,
            [balance.contribution, poolContributionBalance]
        );

        tokenBalance -= share;
        bool succeeded = tokenContract.transfer(recipient, share);
        if (!succeeded) {
            tokenDeposits.undoClaim(recipient, share);
            tokenBalance += share;
        }

        TokenTransfer(recipient, share, succeeded, tokenBalance);
        return tokenBalance;
    }

    function validateContributionSettings() internal constant {
        if (maxContribution > 0) {
            require(maxContribution >= minContribution);
        }
        if (maxPoolBalance > 0) {
            require(maxPoolBalance >= minContribution);
            require(maxPoolBalance >= maxContribution);
        }
    }

    function included(address participant) internal constant returns (bool) {
        return !restricted || balances[participant].whitelisted;
    }

    function getContribution(address participant, uint amount) internal constant returns (uint, uint) {
        ParticipantState storage balance = balances[participant];
        uint total = balance.remaining + balance.contribution + amount;
        uint contribution = total;
        if (!included(participant)) {
            return (0, total);
        }
        if (maxContribution > 0) {
            contribution = Util.min(maxContribution, contribution);
        }
        if (maxPoolBalance > 0) {
            contribution = Util.min(maxPoolBalance - poolContributionBalance, contribution);
        }
        if (contribution < minContribution) {
            return (0, total);
        }
        return (contribution, total - contribution);
    }
}
