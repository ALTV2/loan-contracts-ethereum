// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
//import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CollateralizedLoan is Ownable, ReentrancyGuard {
    // Константы
    uint256 constant SECONDS_PER_DAY = 86400;         // Количество секунд в сутках
    uint256 constant DAYS_PER_MONTH = 30;             // Условное количество дней в месяце
    uint256 constant MONTHS_PER_YEAR = 12;            // Количество месяцев в году
    uint256 constant BASIS_POINTS = 10000;            // Базисные пункты (10000 = 100%)

    // Глобальные параметры
    uint256 public minCollateralRatio = 13000;        // Минимальный коэффициент залога (130%)
    uint256 public minLoanDurationMonths = 1;         // Минимальная длительность займа в месяцах
    uint256 public minLoanAmountInETH = 0.1 ether;    // Минимальная сумма займа в ETH (0.1 ETH)

    // Маппинги
    mapping(address => Loan) public loans;            // Хранит информацию о займах
    mapping(address => TokenInfo) public tokenInfo;   // Хранит информацию о токенах и их параметрах

    // Общие суммы
    uint256 public totalActiveCollateral;             // Общая сумма активного залога в ETH
    uint256 public liquidatedCollateral;              // Общая сумма списанного залога за просрочку

    // Структура для хранения информации о токенах
    struct TokenInfo {
        bool allowed;               // Разрешен ли токен для займов
        uint256 priceInWei;         // Цена 1 токена в wei (например, 1 USDT = 5 * 10**14 wei)
        uint256 interestRate;       // Процентная ставка для этого токена (в базисных пунктах)
        uint256 penaltyRatePerDay;  // Штраф за день просрочки для этого токена (в базисных пунктах)
    }

    // Структура займа
    struct Loan {
        address borrower;           // Заемщик
        IERC20 token;               // Токен займа
        uint256 principal;          // Основная сумма займа
        uint256 collateral;         // Залог в ETH
        uint256 startTime;          // Время начала займа
        uint256 totalDebt;          // Общая сумма долга с процентами
        uint256 monthlyPayment;     // Ежемесячный платеж
        uint256 lastPaymentTime;    // Время последнего платежа
        uint256 paymentsMade;       // Количество совершенных платежей
        uint256 paymentsRequired;   // Общее количество необходимых платежей
        uint256 interestRate;       // Зафиксированная процентная ставка
        uint256 penaltyRatePerDay;  // Зафиксированный штраф за день
        uint256 loanDurationMonths; // Зафиксированная длительность займа
        bool active;                // Статус займа
    }

    // События
    event LoanIssued(address indexed borrower, address token, uint256 amount, uint256 collateral, uint256 duration);
    event PaymentMade(address indexed borrower, uint256 amount, uint256 paymentsMade);
    event LoanFullyRepaid(address indexed borrower, uint256 totalRepaid);
    event EmergencyWithdrawETH(uint256 amount);
    event TokenPriceUpdated(address indexed token, uint256 priceInWei);
    event LoanLiquidated(address indexed borrower, uint256 collateral);
    event EarlyRepayment(address indexed borrower, uint256 amountPaid);

    constructor() {}

    // Добавление токена с параметрами (только владелец)
    function addToken(
        address _token,
        uint256 _priceInWei,
        uint256 _interestRate, // В базисных пунктах
        uint256 _penaltyRatePerDay // В базисных пунктах
    ) external onlyOwner {
        require(_priceInWei > 0, "Price must be greater than 0");
        tokenInfo[_token] = TokenInfo({
            allowed: true,
            priceInWei: _priceInWei,
            interestRate: _interestRate,
            penaltyRatePerDay: _penaltyRatePerDay
        });
        emit TokenPriceUpdated(_token, _priceInWei);
    }

    // Обновление параметров токена (только владелец)
    function updateTokenParams(
        address _token,
        uint256 _priceInWei,
        uint256 _interestRate,
        uint256 _penaltyRatePerDay
    ) external onlyOwner {
        require(tokenInfo[_token].allowed, "Token not allowed");
        require(_priceInWei > 0, "Price must be greater than 0");
        tokenInfo[_token].priceInWei = _priceInWei;
        tokenInfo[_token].interestRate = _interestRate;
        tokenInfo[_token].penaltyRatePerDay = _penaltyRatePerDay;
        emit TokenPriceUpdated(_token, _priceInWei);
    }

    // Внесение токенов в пул (только владелец)
    function depositTokens(IERC20 _token, uint256 _amount) external onlyOwner {
        require(tokenInfo[address(_token)].allowed, "Token not allowed");
        require(_token.transferFrom(msg.sender, address(this), _amount), "Deposit failed");
    }

    // Запрос займа
    function borrow(IERC20 _token, uint256 _amount, uint256 _durationMonths) external payable nonReentrant {
        require(loans[msg.sender].active == false, "Active loan exists");
        TokenInfo memory token = tokenInfo[address(_token)];
        require(token.allowed, "Token not allowed");
        require(msg.value > 0, "ETH collateral required");
        require(_durationMonths >= minLoanDurationMonths, "Duration below minimum");

        // Проверка минимальной суммы займа в ETH
        uint256 loanValueInETH = (_amount * token.priceInWei) / 1e18; // Предполагаем 18 decimals для токенов
        require(loanValueInETH >= minLoanAmountInETH, "Amount below minimum in ETH");

        // Расчет минимального залога
        uint256 minCollateral = (loanValueInETH * minCollateralRatio) / BASIS_POINTS;
        require(msg.value >= minCollateral, "Insufficient collateral");

        // Расчет процентов с учетом точности
        uint256 yearlyInterest = (_amount * token.interestRate) / BASIS_POINTS;
        uint256 proratedInterest = (yearlyInterest * _durationMonths) / MONTHS_PER_YEAR;
        uint256 totalDebt = _amount + proratedInterest;
        uint256 monthlyPayment = totalDebt / _durationMonths;

        // Запись займа
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
            paymentsRequired: _durationMonths,
            interestRate: token.interestRate,
            penaltyRatePerDay: token.penaltyRatePerDay,
            loanDurationMonths: _durationMonths,
            active: true
        });

        totalActiveCollateral += msg.value;
        require(_token.transfer(msg.sender, _amount), "Token transfer failed");
        emit LoanIssued(msg.sender, address(_token), _amount, msg.value, _durationMonths);
    }

    // Ежемесячный платеж
    function makeMonthlyPayment() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active loan");
        require(loan.paymentsMade < loan.paymentsRequired, "Loan fully paid");

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime;
        uint256 paymentAmount = loan.monthlyPayment;

        // Начисление штрафа, если просрочка больше месяца
        if (timeSinceLastPayment > DAYS_PER_MONTH * SECONDS_PER_DAY) {
            uint256 daysLate = (timeSinceLastPayment - DAYS_PER_MONTH * SECONDS_PER_DAY) / SECONDS_PER_DAY;
            uint256 penalty = (loan.totalDebt * loan.penaltyRatePerDay * daysLate) / BASIS_POINTS;
            paymentAmount += penalty;
        }

        require(loan.token.transferFrom(msg.sender, address(this), paymentAmount), "Payment failed");

        loan.lastPaymentTime = block.timestamp;
        loan.paymentsMade++;
        loan.totalDebt -= loan.monthlyPayment;

        emit PaymentMade(msg.sender, paymentAmount, loan.paymentsMade);

        if (loan.paymentsMade == loan.paymentsRequired && loan.totalDebt <= 0) {
            loan.active = false;
            totalActiveCollateral -= loan.collateral;
            payable(msg.sender).transfer(loan.collateral);
            emit LoanFullyRepaid(msg.sender, loan.principal + (loan.monthlyPayment * loan.paymentsRequired));
        }
    }

    // Досрочное погашение
    function repayEarly() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active loan");

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime;
        uint256 paymentAmount = loan.totalDebt;

        // Если есть просрочка, добавляем штраф
        if (timeSinceLastPayment > DAYS_PER_MONTH * SECONDS_PER_DAY) {
            uint256 daysLate = (timeSinceLastPayment - DAYS_PER_MONTH * SECONDS_PER_DAY) / SECONDS_PER_DAY;
            uint256 penalty = (loan.totalDebt * loan.penaltyRatePerDay * daysLate) / BASIS_POINTS;
            paymentAmount += penalty;
        }

        require(loan.token.transferFrom(msg.sender, address(this), paymentAmount), "Payment failed");

        loan.active = false;
        totalActiveCollateral -= loan.collateral;
        payable(msg.sender).transfer(loan.collateral);

        emit EarlyRepayment(msg.sender, paymentAmount);
        emit LoanFullyRepaid(msg.sender, paymentAmount);
    }

    // Аварийный вывод ETH с учетом ликвидации просрочек (теперь выводит только ликвидированные залоги)
    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        uint256 freeETH = liquidatedCollateral;
        require(freeETH > 0, "No free ETH to withdraw");
        payable(owner()).transfer(freeETH);
        emit EmergencyWithdrawETH(freeETH);
    }

    // Ликвидация просроченного займа (только владелец)
    function liquidateLoan(address _borrower) external onlyOwner nonReentrant {
        Loan storage loan = loans[_borrower];
        require(loan.active, "No active loan");

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime;
        require(timeSinceLastPayment > 60 * SECONDS_PER_DAY, "Not overdue enough"); // 2 месяца просрочки

        loan.active = false;
        totalActiveCollateral -= loan.collateral;
        liquidatedCollateral += loan.collateral;
        emit LoanLiquidated(_borrower, loan.collateral);
    }

    // Обновление глобальных параметров
    function updateParameters(uint256 _minCollateralRatio, uint256 _minLoanDurationMonths, uint256 _minLoanAmountInETH) external onlyOwner {
        minCollateralRatio = _minCollateralRatio;
        minLoanDurationMonths = _minLoanDurationMonths;
        minLoanAmountInETH = _minLoanAmountInETH;
    }

    // Получение деталей займа
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
        uint256 nextDue = loan.active ? loan.lastPaymentTime + (DAYS_PER_MONTH * SECONDS_PER_DAY) : 0;
        return (
            address(loan.token),
            loan.principal,
            loan.collateral,
            loan.totalDebt,
            loan.monthlyPayment,
            nextDue,
            loan.paymentsMade,
            loan.paymentsRequired,
            loan.active
        );
    }

    // Получение текущих параметров займа для токена
    function getTokenLoanParams(address _token) external view returns (
        bool allowed,
        uint256 priceInWei,
        uint256 interestRate,
        uint256 penaltyRatePerDay
    ) {
        TokenInfo memory token = tokenInfo[_token];
        return (token.allowed, token.priceInWei, token.interestRate, token.penaltyRatePerDay);
    }
}