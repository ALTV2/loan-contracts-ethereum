// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
//import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CollateralizedLoan
 * @dev Контракт займа с гибкими параметрами и повышенной надежностью
 */
contract CollateralizedLoan is ReentrancyGuard, Ownable {
    // Константы
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant MONTHS_PER_YEAR = 12;
    uint256 public constant BASIS_POINTS = 10000; // 10000 = 100%
    uint256 public constant MIN_COLLATERAL_RATIO = 15000; // 150% в базисных пунктах
    uint256 public constant DAYS_PER_MONTH = 30;
    uint256 public constant MAX_LOAN_DURATION_MONTHS = 36; // Максимальная длительность займа
    uint256 public constant LIQUIDATION_THRESHOLD_DAYS = 60; // Порог ликвидации в днях

    // Настраиваемые параметры
    uint256 public interestRate; // Годовая процентная ставка (в базисных пунктах)
    uint256 public penaltyRatePerDay; // Штраф за день просрочки (в базисных пунктах)
    uint256 public loanDurationMonths; // Длительность займа в месяцах (настраиваемая)

    struct Loan {
        address borrower;          // Адрес заемщика
        IERC20 token;             // Токен займа
        uint256 principal;        // Основная сумма займа
        uint256 collateral;       // Сумма залога в ETH
        uint256 startTime;        // Время начала займа
        uint256 totalDebt;        // Общая сумма долга с процентами
        uint256 monthlyPayment;   // Ежемесячный платеж
        uint256 lastPaymentTime;  // Время последнего платежа
        uint256 paymentsMade;     // Количество совершенных платежей
        uint256 paymentsRequired; // Общее количество необходимых платежей
        bool active;             // Статус займа
    }

    // Маппинг займов
    mapping(address => Loan) public loans;

    // Разрешенные токены для займов (для безопасности)
    mapping(address => bool) public allowedTokens;

    // Минимальная сумма займа в wei эквиваленте
    uint256 public minLoanAmount;

    event LoanIssued(address indexed borrower, address token, uint256 amount, uint256 collateral, uint256 durationMonths);
    event PaymentMade(address indexed borrower, uint256 amount, uint256 paymentNumber);
    event LoanFullyRepaid(address indexed borrower, uint256 totalPaid);
    event CollateralLiquidated(address indexed borrower, uint256 collateralAmount);
    event ParametersUpdated(uint256 interestRate, uint256 penaltyRate, uint256 loanDuration);
    event TokenStatusChanged(address token, bool allowed);

    constructor(
        uint256 _interestRate,
        uint256 _penaltyRatePerDay,
        uint256 _loanDurationMonths,
        uint256 _minLoanAmount
    ) Ownable(msg.sender) {
        require(_loanDurationMonths <= MAX_LOAN_DURATION_MONTHS, "Duration exceeds maximum");
        interestRate = _interestRate;
        penaltyRatePerDay = _penaltyRatePerDay;
        loanDurationMonths = _loanDurationMonths;
        minLoanAmount = _minLoanAmount;
    }

    /**
     * @dev Обновление параметров займа (только владелец)
     */
    function updateParameters(
        uint256 _interestRate,
        uint256 _penaltyRatePerDay,
        uint256 _loanDurationMonths
    ) external onlyOwner {
        require(_loanDurationMonths <= MAX_LOAN_DURATION_MONTHS, "Duration exceeds maximum");
        interestRate = _interestRate;
        penaltyRatePerDay = _penaltyRatePerDay;
        loanDurationMonths = _loanDurationMonths;
        emit ParametersUpdated(_interestRate, _penaltyRatePerDay, _loanDurationMonths);
    }

    /**
     * @dev Управление списком разрешенных токенов
     */
    function setTokenAllowed(address _token, bool _allowed) external onlyOwner {
        allowedTokens[_token] = _allowed;
        emit TokenStatusChanged(_token, _allowed);
    }

    /**
     * @dev Запрос займа
     */
    function borrow(IERC20 _token, uint256 _amount) external payable nonReentrant {
        require(loans[msg.sender].borrower == address(0), "Active loan exists");
        require(allowedTokens[address(_token)], "Token not allowed");
        require(msg.value > 0, "ETH collateral required");
        require(_amount >= minLoanAmount, "Amount below minimum");

        uint256 minCollateral = (_amount * MIN_COLLATERAL_RATIO) / BASIS_POINTS;
        require(msg.value >= minCollateral, "Insufficient collateral");

        uint256 yearlyInterest = (_amount * interestRate) / BASIS_POINTS;
        uint256 totalDebt = _amount + yearlyInterest;
        uint256 monthlyPayment = totalDebt / loanDurationMonths;

        loans[msg.sender] = Loan({
            borrower: msg.sender,
            token: _token,
            principal: _amount,
            collateral: msg.value,
            startTime: block.timestamp,
            totalDebt: totalDebt,
            monthlyPayment: monthlyPayment,
            lastPaymentTime: block.timestamp,
            paymentsMade: 0,
            paymentsRequired: loanDurationMonths,
            active: true
        });

        require(_token.transferFrom(owner(), msg.sender, _amount), "Token transfer failed");
        emit LoanIssued(msg.sender, address(_token), _amount, msg.value, loanDurationMonths);
    }

    /**
     * @dev Ежемесячный платеж
     */
    function makeMonthlyPayment() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active loan");
        require(loan.paymentsMade < loan.paymentsRequired, "Loan fully paid");

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime;
        require(timeSinceLastPayment >= DAYS_PER_MONTH * SECONDS_PER_DAY, "Payment not due yet");

        uint256 paymentAmount = loan.monthlyPayment;

        if (timeSinceLastPayment > DAYS_PER_MONTH * SECONDS_PER_DAY) {
            uint256 daysLate = (timeSinceLastPayment - (DAYS_PER_MONTH * SECONDS_PER_DAY)) / SECONDS_PER_DAY;
            uint256 penalty = (loan.monthlyPayment * penaltyRatePerDay * daysLate) / BASIS_POINTS;
            paymentAmount += penalty;
        }

        require(loan.token.transferFrom(msg.sender, owner(), paymentAmount), "Payment failed");

        loan.lastPaymentTime = block.timestamp;
        loan.paymentsMade++;
        loan.totalDebt -= loan.monthlyPayment;

        emit PaymentMade(msg.sender, paymentAmount, loan.paymentsMade);

        if (loan.paymentsMade == loan.paymentsRequired) {
            loan.active = false;
            payable(msg.sender).transfer(loan.collateral);
            emit LoanFullyRepaid(msg.sender, loan.principal + (loan.monthlyPayment * loan.paymentsRequired));
        }
    }

    /**
     * @dev Ликвидация залога
     */
    function liquidate(address _borrower) external onlyOwner nonReentrant {
        Loan storage loan = loans[_borrower];
        require(loan.active, "No active loan");

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime;
        require(timeSinceLastPayment > LIQUIDATION_THRESHOLD_DAYS * SECONDS_PER_DAY, "Not enough overdue time");

        loan.active = false;
        payable(owner()).transfer(loan.collateral);
        emit CollateralLiquidated(_borrower, loan.collateral);
    }

    /**
     * @dev Информация о займе
     */
    function getLoanDetails(address _borrower) external view returns (
        address token,
        uint256 principal,
        uint256 collateral,
        uint256 totalDebt,
        uint256 monthlyPayment,
        uint256 nextPaymentDue,
        uint256 paymentsMade,
        uint256 paymentsRequired,
        bool active
    ) {
        Loan memory loan = loans[_borrower];
        return (
            address(loan.token),
            loan.principal,
            loan.collateral,
            loan.totalDebt,
            loan.monthlyPayment,
            loan.lastPaymentTime + (DAYS_PER_MONTH * SECONDS_PER_DAY),
            loan.paymentsMade,
            loan.paymentsRequired,
            loan.active
        );
    }

    /**
     * @dev Аварийное извлечение ETH (только владелец)
     */
    function emergencyWithdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
    }
}