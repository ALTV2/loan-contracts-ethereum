// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CollateralizedLoan is Ownable, ReentrancyGuard {
    // Константы
    uint256 constant SECONDS_PER_DAY = 86400;         // Количество секунд в сутках
    uint256 constant DAYS_PER_MONTH = 30;             // Условное количество дней в месяце (для упрощения)
    uint256 constant MONTHS_PER_YEAR = 12;            // Количество месяцев в году
    uint256 constant BASIS_POINTS = 10000;            // Базисные пункты (10000 = 100%)
    uint256 constant MIN_COLLATERAL_RATIO = 13000;    // Минимальный коэффициент залога (130%) //todo можно вынести в изменяемые параметры

    // Глобальные параметры
    uint256 public interestRate = 1000;               // Годовая процентная ставка по умолчанию (10%)
    uint256 public penaltyRatePerDay = 50;            // Штраф за день просрочки (0.5%)
    uint256 public loanDurationMonths = 12;           // Длительность займа по умолчанию (12 месяцев)
    uint256 public minLoanAmount = 100 * 10**18;      // Минимальная сумма займа

    // Маппинги
    mapping(address => Loan) public loans;            // Хранит информацию о займах
    mapping(address => TokenInfo) public tokenInfo;   // Хранит информацию о разрешенных токенах и их ценах

    // Общая сумма активного залога в ETH
    uint256 public totalActiveCollateral;

    // Структура для хранения информации о токенах
    struct TokenInfo {
        bool allowed;           // Разрешен ли токен для займов
        uint256 priceInWei;     // Цена 1 токена в wei (например, 1 USDT = 5 * 10**14 wei)
    }

    // Структура займа
    struct Loan {
        address borrower;           // Заемщик
        IERC20 token;               // Токен
        uint256 principal;          // Основная сумма займа (без процентов)
        uint256 collateral;         // Обеспечение (сумма ETH, внесенная как залог)
        uint256 startTime;          // Время начала займа (время блока в секундах)
        uint256 totalDebt;          // Общая сумма долга (основной долг + проценты)
        uint256 monthlyPayment;     // Ежемесячный платеж
        uint256 lastPaymentTime;    // Время последнего платежа (время блока в секундах)
        uint256 paymentsMade;       // Количество совершенных платежей
        uint256 paymentsRequired;   // Общее количество необходимых платежей
        uint256 interestRate;       // Процентная ставка, зафиксированная для этого займа
        uint256 penaltyRatePerDay;  // Штраф за день просрочки, зафиксированный для этого займа
        uint256 loanDurationMonths; // Длительность займа в месяцах, зафиксированная для этого займа
        bool active;                // Активный или погашенный
    }

    // События
    event LoanIssued(address indexed borrower, address token, uint256 amount, uint256 collateral, uint256 duration); // регистрация займа
    event PaymentMade(address indexed borrower, uint256 amount, uint256 paymentsMade); // внесение платежа
    event LoanFullyRepaid(address indexed borrower, uint256 totalRepaid); // полное погашение
    event EmergencyWithdrawETH(uint256 amount); // экстренный вывод (скам)
    event TokenPriceUpdated(address indexed token, uint256 priceInWei); // Событие для обновления цены токена

    constructor() {}

    // Функция для добавления токена и установки его цены (только владелец)
    function addToken(address _token, uint256 _priceInWei) external onlyOwner {
        require(_priceInWei > 0, "Price must be greater than 0");
        tokenInfo[_token] = TokenInfo({
            allowed: true,          // Токен становится разрешенным
            priceInWei: _priceInWei // Устанавливается цена в ETH за 1 токен (wei)
        });
        emit TokenPriceUpdated(_token, _priceInWei);
    }

    // Функция для обновления цены токена (только владелец)
    function updateTokenPrice(address _token, uint256 _priceInWei) external onlyOwner {
        require(tokenInfo[_token].allowed, "Token not allowed");
        require(_priceInWei > 0, "Price must be greater than 0");
        tokenInfo[_token].priceInWei = _priceInWei;
        emit TokenPriceUpdated(_token, _priceInWei);
    }

    // Функция для внесения токенов в пул контракта (только владелец)
    function depositTokens(IERC20 _token, uint256 _amount) external onlyOwner {
        require(tokenInfo[address(_token)].allowed, "Token not allowed");
        require(_token.transferFrom(msg.sender, address(this), _amount), "Deposit failed");
    }

    // Функция для запроса займа
    function borrow(IERC20 _token, uint256 _amount) external payable nonReentrant {
        require(loans[msg.sender].active == false, "Active loan exists");
        TokenInfo memory token = tokenInfo[address(_token)];
        require(token.allowed, "Token not allowed");
        require(msg.value > 0, "ETH collateral required");
        require(_amount >= minLoanAmount, "Amount below minimum");        // todo тут лучше опираться на стоимость в Eth

        // Расчет минимального залога с учетом цены токена
        // Сначала вычисляем стоимость займа в ETH: (количество токенов * цена токена в ETH)
        uint256 loanValueInETH = (_amount * token.priceInWei);
        uint256 minCollateral = (loanValueInETH * MIN_COLLATERAL_RATIO) / BASIS_POINTS; // Минимальный залог (130%)
        require(msg.value >= minCollateral, "Insufficient collateral");                 // Проверяем залог

        // Расчет процентов и долга //todo кажется что могут быть зазоры
        uint256 yearlyInterest = (_amount * interestRate) / BASIS_POINTS;                   // Годовые проценты
        uint256 proratedInterest = (yearlyInterest * loanDurationMonths) / MONTHS_PER_YEAR; // Пропорциональные проценты
        uint256 totalDebt = _amount + proratedInterest;                                     // Общий долг
        uint256 monthlyPayment = totalDebt / loanDurationMonths;                            // Ежемесячный платеж

        // Записываем данные займа
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
            interestRate: interestRate,
            penaltyRatePerDay: penaltyRatePerDay,
            loanDurationMonths: loanDurationMonths,
            active: true
        });

        totalActiveCollateral += msg.value; // Увеличиваем общий залог

        require(_token.balanceOf(address(this)) >= _amount, "Insufficient tokens in pool"); // Проверяем пул
        require(_token.transfer(msg.sender, _amount), "Token transfer failed");           // Переводим токены заемщику

        emit LoanIssued(msg.sender, address(_token), _amount, msg.value, loanDurationMonths);
    }

    //todo реализовать функцию для досрочного погашения

    // Функция для ежемесячного платежа
    function makeMonthlyPayment() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active loan");
        require(loan.paymentsMade < loan.paymentsRequired, "Loan fully paid");

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime;
        require(timeSinceLastPayment >= DAYS_PER_MONTH * SECONDS_PER_DAY, "Payment not due yet"); //todo спорно

        uint256 paymentAmount = loan.monthlyPayment;
        if (timeSinceLastPayment > DAYS_PER_MONTH * SECONDS_PER_DAY) {
            uint256 daysLate = (timeSinceLastPayment - (DAYS_PER_MONTH * SECONDS_PER_DAY)) / SECONDS_PER_DAY;
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

    // Функция для аварийного вывода ETH
    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        //todo если у кого-то просрочка больше 2х месяцев, то нужно списывать весь эфир(в свою пользу) и гасить долг в маппинге
        uint256 freeETH = address(this).balance - totalActiveCollateral; //todo можно украсть ефир, нужно отдельно хранить кол-во списанного эфира за долги
        require(freeETH > 0, "No free ETH to withdraw");
        payable(owner()).transfer(freeETH);
        emit EmergencyWithdrawETH(freeETH);
    }

    // Функция для обновления глобальных параметров //todo можно вынести в структуру токенов
    function updateParameters(uint256 _interestRate, uint256 _penaltyRate, uint256 _duration) external onlyOwner {
        interestRate = _interestRate; //todo можно вынести в структуру c информацией по токену
        penaltyRatePerDay = _penaltyRate; //todo можно вынести в структуру c информацией по токену
        loanDurationMonths = _duration; //todo тут должна быть только фиксация минимального срока займа, а фактическое время займа нужно вынести в метод borrow
    }

    //todo Переписать метод корректно для данной реализации
//    function getLoanDetails(address _borrower) external view returns (
//        address token,
//        uint256 principal,
//        uint256 collateral,
//        uint256 totalDebt,
//        uint256 monthlyPayment,
//        uint256 nextPaymentDue,
//        uint256 paymentsMade,
//        uint256 paymentsRequired,
//        bool active
//    ) {
//        Loan memory loan = loans[_borrower];
//        return (
//            address(loan.token),
//            loan.principal,
//            loan.collateral,
//            loan.totalDebt,
//            loan.monthlyPayment,
//            loan.lastPaymentTime + (DAYS_PER_MONTH * SECONDS_PER_DAY),
//            loan.paymentsMade,
//            loan.paymentsRequired,
//            loan.active
//        );
//    }

    //todo метод для получения информации о процентах и тд на займ конкретного токена в данный момент
}