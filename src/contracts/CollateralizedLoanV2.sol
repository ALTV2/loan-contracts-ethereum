// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
//import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CollateralizedLoan is Ownable, ReentrancyGuard {

    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant DAYS_PER_MONTH = 30;             // Условное количество дней в месяце (для упрощения расчетов)
    uint256 constant MONTHS_PER_YEAR = 12;
    uint256 constant BASIS_POINTS = 10000;            // Базисные пункты для процентов (10000 = 100%)
    uint256 constant MIN_COLLATERAL_RATIO = 15000;    // Минимальный коэффициент залога в базисных пунктах (150% от суммы займа)

    // (могут быть изменены владельцем, но не ретроспективно)
    uint256 public interestRate = 1000;               // Годовая процентная ставка по умолчанию (10% = 1000 базисных пунктов)
    uint256 public penaltyRatePerDay = 50;            // Штраф за день просрочки по умолчанию (0.5% = 50 базисных пунктов)
    uint256 public loanDurationMonths = 12;           // Длительность займа по умолчанию в месяцах (12 месяцев)
    uint256 public minLoanAmount = 100 * 10**18;      // Минимальная сумма займа в wei-эквиваленте (100 токенов с 18 десятичными знаками)

    mapping(address => Loan) public loans;            // Хранит информацию о займах для каждого заемщика (ключ — адрес заемщика)
    mapping(address => bool) public allowedTokens;    // Список разрешенных токенов для займов
    uint256 public totalActiveCollateral;             // Общая сумма ETH, заблокированного в качестве залога для активных займов

    // Структура описывает параметры каждого займа
    struct Loan {
        address borrower;               // Адрес заемщика
        IERC20 token;                   // Токен ERC20, в котором выдан займ
        uint256 principal;              // Основная сумма займа (без процентов)
        uint256 collateral;             // Сумма ETH, внесенная как залог
        uint256 startTime;              // Время начала займа (время блока в секундах)
        uint256 totalDebt;              // Общая сумма долга (основной долг + проценты)
        uint256 monthlyPayment;         // Размер ежемесячного платежа
        uint256 lastPaymentTime;        // Время последнего платежа (время блока в секундах)
        uint256 paymentsMade;           // Количество совершенных платежей
        uint256 paymentsRequired;       // Общее количество необходимых платежей (равно длительности займа в месяцах)
        uint256 interestRate;           // Процентная ставка, зафиксированная для этого займа
        uint256 penaltyRatePerDay;      // Штраф за день просрочки, зафиксированный для этого займа
        uint256 loanDurationMonths;     // Длительность займа в месяцах, зафиксированная для этого займа
        bool active;                    // Статус займа (true — активен, false — закрыт)
    }

    // События для отслеживания ключевых действий в контракте
    event LoanIssued(address indexed borrower, address token, uint256 amount, uint256 collateral, uint256 duration); // Выдача займа
    event PaymentMade(address indexed borrower, uint256 amount, uint256 paymentsMade);                              // Совершение платежа
    event LoanFullyRepaid(address indexed borrower, uint256 totalRepaid);                                          // Полное погашение займа
    event EmergencyWithdrawETH(uint256 amount);                                                                   // Аварийный вывод ETH владельцем

    // (пустой, так как параметры задаются по умолчанию)
    constructor() {}

    // Функция для добавления токена в список разрешенных
    function addToken(address _token) external onlyOwner {
        allowedTokens[_token] = true;
    }

    // Функция для внесения токенов в пул контракта (только владелец)
    function depositTokens(IERC20 _token, uint256 _amount) external onlyOwner {
        require(_token.transferFrom(msg.sender, address(this), _amount), "Deposit failed"); // Перевести токены от владельца в контракт
        // Если перевод не удался, транзакция отменяется с сообщением "Deposit failed"
    }

    // Функция для запроса займа
    function borrow(IERC20 _token, uint256 _amount) external payable nonReentrant {
        // Модификатор nonReentrant предотвращает повторный вход в функцию (защита от атак)
        require(loans[msg.sender].active == false, "Active loan exists"); // Убедиться, что у заемщика нет активного займа
        require(allowedTokens[address(_token)], "Token not allowed");     // Проверить, что токен разрешен для займов
        require(msg.value > 0, "ETH collateral required");                // Убедиться, что заемщик отправил ETH как залог
        require(_amount >= minLoanAmount, "Amount below minimum");        // Проверить, что сумма займа не меньше минимальной

        uint256 minCollateral = (_amount * MIN_COLLATERAL_RATIO) / BASIS_POINTS; // Рассчитать минимальный залог (150% от суммы займа)
        require(msg.value >= minCollateral, "Insufficient collateral");           // Проверить, что залог достаточен

        // Расчет процентов с учетом длительности займа
        uint256 yearlyInterest = (_amount * interestRate) / BASIS_POINTS;        // Годовые проценты
        uint256 proratedInterest = (yearlyInterest * loanDurationMonths) / MONTHS_PER_YEAR; // Пропорциональные проценты
        uint256 totalDebt = _amount + proratedInterest;                          // Общий долг = сумма займа + проценты
        uint256 monthlyPayment = totalDebt / loanDurationMonths;                 // Ежемесячный платеж (упрощенный расчет)

        // Создание записи о займе в отображении loans
        loans[msg.sender] = Loan({
            borrower: msg.sender,               // Адрес заемщика
            token: _token,                      // Токен займа
            principal: _amount,                 // Основная сумма
            collateral: msg.value,              // Залог в ETH
            startTime: block.timestamp,         // Время начала займа
            totalDebt: totalDebt,               // Общий долг
            monthlyPayment: monthlyPayment,     // Ежемесячный платеж
            lastPaymentTime: block.timestamp,   // Время последнего платежа (изначально равно началу)
            paymentsMade: 0,                    // Количество платежей (изначально 0)
            paymentsRequired: loanDurationMonths, // Количество необходимых платежей
            interestRate: interestRate,         // Фиксация процентной ставки
            penaltyRatePerDay: penaltyRatePerDay, // Фиксация штрафа
            loanDurationMonths: loanDurationMonths, // Фиксация длительности
            active: true                        // Займ активен
        });

        totalActiveCollateral += msg.value;     // Увеличить общий активный залог на сумму внесенного ETH

        require(_token.balanceOf(address(this)) >= _amount, "Insufficient tokens in pool"); // Проверить, что в пуле достаточно токенов
        require(_token.transfer(msg.sender, _amount), "Token transfer failed");             // Перевести токены заемщику

        emit LoanIssued(msg.sender, address(_token), _amount, msg.value, loanDurationMonths); // Вызвать событие о выдаче займа
    }

    // Функция для внесения ежемесячного платежа (Модификатор nonReentrant предотвращает повторный вход)
    function makeMonthlyPayment() external nonReentrant {
        Loan storage loan = loans[msg.sender];                  // Получить данные займа текущего заемщика
        require(loan.active, "No active loan");                 // Убедиться, что займ активен
        require(loan.paymentsMade < loan.paymentsRequired, "Loan fully paid"); // Проверить, что займ еще не погашен полностью

        uint256 timeSinceLastPayment = block.timestamp - loan.lastPaymentTime; // Время с последнего платежа
        require(timeSinceLastPayment >= DAYS_PER_MONTH * SECONDS_PER_DAY, "Payment not due yet"); // Убедиться, что платеж просрочен

        uint256 paymentAmount = loan.monthlyPayment; // Базовый платеж — ежемесячная сумма
        if (timeSinceLastPayment > DAYS_PER_MONTH * SECONDS_PER_DAY) {
            // Если платеж просрочен
            uint256 daysLate = (timeSinceLastPayment - (DAYS_PER_MONTH * SECONDS_PER_DAY)) / SECONDS_PER_DAY; // Количество дней просрочки
            uint256 penalty = (loan.totalDebt * loan.penaltyRatePerDay * daysLate) / BASIS_POINTS;            // Штраф на основе остатка долга
            paymentAmount += penalty;                                                                         // Добавить штраф к платежу
        }

        require(loan.token.transferFrom(msg.sender, address(this), paymentAmount), "Payment failed"); // Перевести платеж в контракт

        loan.lastPaymentTime = block.timestamp;    // Обновить время последнего платежа
        loan.paymentsMade++;                       // Увеличить счетчик платежей
        loan.totalDebt -= loan.monthlyPayment;     // Уменьшить общий долг на сумму ежемесячного платежа (без учета штрафа)

        emit PaymentMade(msg.sender, paymentAmount, loan.paymentsMade); // Вызвать событие о платеже

        if (loan.paymentsMade == loan.paymentsRequired && loan.totalDebt <= 0) {
            // Если все платежи сделаны и долг погашен
            loan.active = false;                   // Деактивировать займ
            totalActiveCollateral -= loan.collateral; // Уменьшить общий активный залог
            payable(msg.sender).transfer(loan.collateral); // Вернуть залог заемщику
            emit LoanFullyRepaid(msg.sender, loan.principal + (loan.monthlyPayment * loan.paymentsRequired)); // Вызвать событие о полном погашении
        }
    }

    // Функция для аварийного вывода ETH (только владелец)
    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        // Модификатор onlyOwner ограничивает доступ владельцем, nonReentrant — защищает от повторного входа
        uint256 freeETH = address(this).balance - totalActiveCollateral; // Свободный ETH = баланс контракта минус активные залоги
        require(freeETH > 0, "No free ETH to withdraw");                 // Убедиться, что есть что выводить
        payable(owner()).transfer(freeETH);                             // Перевести свободный ETH владельцу
        emit EmergencyWithdrawETH(freeETH);                             // Вызвать событие о выводе
    }

    // Функция для обновления глобальных параметров (только владелец)
    function updateParameters(uint256 _interestRate, uint256 _penaltyRate, uint256 _duration) external onlyOwner {
        // Модификатор onlyOwner ограничивает доступ владельцем
        interestRate = _interestRate;           // Обновить процентную ставку
        penaltyRatePerDay = _penaltyRate;       // Обновить штраф за день просрочки
        loanDurationMonths = _duration;         // Обновить длительность займа
        // Эти изменения применяются только к новым займам, так как параметры фиксируются в структуре Loan
    }
}