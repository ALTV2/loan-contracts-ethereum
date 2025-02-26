const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CollateralizedLoan - Multi-User Scenarios", function () {
  let CollateralizedLoan, loanContract, MockToken, token;
  let owner, user1, user2, user3, liquidator;
  const INTEREST_RATE = 500; // 5%
  const PENALTY_RATE = 10; // 0.1% в день
  const LOAN_DURATION_MONTHS = 12;
  const MIN_LOAN_AMOUNT = ethers.parseEther("1"); // 1 токен
  const LOAN_AMOUNT = ethers.parseEther("2"); // 2 токена
  const COLLATERAL_AMOUNT = ethers.parseEther("3"); // 3 ETH (150% от 2 токенов)

  beforeEach(async function () {
    [owner, user1, user2, user3, liquidator] = await ethers.getSigners();

    // Деплой mock ERC-20 токена
    MockToken = await ethers.getContractFactory("MockERC20");
    token = await MockToken.deploy("Test Token", "TST", ethers.parseEther("1000"));
    await token.waitForDeployment();

    // Деплой контракта займа
    CollateralizedLoan = await ethers.getContractFactory("CollateralizedLoan");
    loanContract = await CollateralizedLoan.deploy(
      INTEREST_RATE,
      PENALTY_RATE,
      LOAN_DURATION_MONTHS,
      MIN_LOAN_AMOUNT
    );
    await loanContract.waitForDeployment();

    // Настройка: одобрение токенов и разрешение токена
    await token.connect(owner).approve(loanContract.target, ethers.parseEther("1000"));
    await loanContract.connect(owner).setTokenAllowed(token.target, true);

    // Передаем токены пользователям для платежей
    await token.connect(owner).transfer(user1.address, ethers.parseEther("50"));
    await token.connect(owner).transfer(user2.address, ethers.parseEther("50"));
    await token.connect(owner).transfer(user3.address, ethers.parseEther("50"));
  });

  describe("Multiple Users Borrowing", function () {
    it("Should allow multiple users to borrow successfully", async function () {
      // User1 берет займ
      await expect(
        loanContract.connect(user1).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT })
      )
        .to.emit(loanContract, "LoanIssued")
        .withArgs(user1.address, token.target, LOAN_AMOUNT, COLLATERAL_AMOUNT, LOAN_DURATION_MONTHS);

      // User2 берет займ
      await expect(
        loanContract.connect(user2).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT })
      )
        .to.emit(loanContract, "LoanIssued")
        .withArgs(user2.address, token.target, LOAN_AMOUNT, COLLATERAL_AMOUNT, LOAN_DURATION_MONTHS);

      // User3 берет займ
      await expect(
        loanContract.connect(user3).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT })
      )
        .to.emit(loanContract, "LoanIssued")
        .withArgs(user3.address, token.target, LOAN_AMOUNT, COLLATERAL_AMOUNT, LOAN_DURATION_MONTHS);

      // Проверка деталей займов
      const loan1 = await loanContract.getLoanDetails(user1.address);
      const loan2 = await loanContract.getLoanDetails(user2.address);
      const loan3 = await loanContract.getLoanDetails(user3.address);

      expect(loan1.principal).to.equal(LOAN_AMOUNT);
      expect(loan2.principal).to.equal(LOAN_AMOUNT);
      expect(loan3.principal).to.equal(LOAN_AMOUNT);
      expect(loan1.active).to.be.true;
      expect(loan2.active).to.be.true;
      expect(loan3.active).to.be.true;
    });
  });

  describe("Timely Payments Scenario", function () {
    it("User1 repays loan on time", async function () {
      await loanContract.connect(user1).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      await token.connect(user1).approve(loanContract.target, ethers.parseEther("50"));

      const initialBalance = await ethers.provider.getBalance(user1.address);
      const monthlyPayment = (await loanContract.getLoanDetails(user1.address)).monthlyPayment;

      // Выполняем 12 платежей вовремя
      for (let i = 0; i < LOAN_DURATION_MONTHS; i++) {
        await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]); // 30 дней
        await ethers.provider.send("evm_mine");
        await expect(loanContract.connect(user1).makeMonthlyPayment())
          .to.emit(loanContract, "PaymentMade")
          .withArgs(user1.address, monthlyPayment, i + 1);
      }

      const loan = await loanContract.getLoanDetails(user1.address);
      expect(loan.active).to.be.false;
      expect(loan.paymentsMade).to.equal(LOAN_DURATION_MONTHS);

      const finalBalance = await ethers.provider.getBalance(user1.address);
      expect(finalBalance).to.be.closeTo(initialBalance, ethers.parseEther("10")); // Учитываем газ
    });
  });

  describe("Late Payments with Penalty", function () {
    it("User2 pays late and incurs penalty", async function () {
      await loanContract.connect(user2).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      await token.connect(user2).approve(loanContract.target, ethers.parseEther("50"));

      // Первый платеж с опозданием на 10 дней
      await ethers.provider.send("evm_increaseTime", [40 * 24 * 60 * 60]); // 40 дней
      await ethers.provider.send("evm_mine");

      const loanBefore = await loanContract.getLoanDetails(user2.address);
      const basePayment = loanBefore.monthlyPayment;
      const penalty = (basePayment * BigInt(PENALTY_RATE) * BigInt(10)) / BigInt(10000); // 10 дней просрочки
      const expectedPayment = basePayment + penalty;

      await expect(loanContract.connect(user2).makeMonthlyPayment())
        .to.emit(loanContract, "PaymentMade")
        .withArgs(user2.address, expectedPayment, 1);

      const loanAfter = await loanContract.getLoanDetails(user2.address);
      expect(loanAfter.paymentsMade).to.equal(1);
      expect(loanAfter.totalDebt).to.equal(loanBefore.totalDebt - basePayment);
    });
  });

  describe("Liquidation Scenario", function () {
    it("User3 misses payments and gets liquidated", async function () {
      await loanContract.connect(user3).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      await token.connect(user3).approve(loanContract.target, ethers.parseEther("50"));

      // Первый платеж вовремя
      await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await loanContract.connect(user3).makeMonthlyPayment();

      // Пропускаем платежи на 61 день
      await ethers.provider.send("evm_increaseTime", [61 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
      await expect(loanContract.connect(owner).liquidate(user3.address))
        .to.emit(loanContract, "CollateralLiquidated")
        .withArgs(user3.address, COLLATERAL_AMOUNT);

      const ownerBalanceAfter = await ethers.provider.getBalance(owner.address);
      const loan = await loanContract.getLoanDetails(user3.address);

      expect(loan.active).to.be.false;
      expect(ownerBalanceAfter).to.be.above(ownerBalanceBefore);
      expect(ownerBalanceAfter).to.be.closeTo(
        ownerBalanceBefore + COLLATERAL_AMOUNT,
        ethers.parseEther("0.1") // Учитываем газ
      );
    });
  });

  describe("Mixed Scenarios", function () {
    it("Multiple users with different behaviors", async function () {
      // User1: Своевременные платежи
      await loanContract.connect(user1).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      await token.connect(user1).approve(loanContract.target, ethers.parseEther("50"));

      // User2: Частичные платежи с просрочкой
      await loanContract.connect(user2).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      await token.connect(user2).approve(loanContract.target, ethers.parseEther("50"));

      // User3: Пропуск платежей и ликвидация
      await loanContract.connect(user3).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      await token.connect(user3).approve(loanContract.target, ethers.parseEther("50"));

      // User1: 6 своевременных платежей
      for (let i = 0; i < 6; i++) {
        await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
        await ethers.provider.send("evm_mine");
        await loanContract.connect(user1).makeMonthlyPayment();
      }

      // User2: 2 платежа с просрочкой на 10 дней
      await ethers.provider.send("evm_increaseTime", [40 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await loanContract.connect(user2).makeMonthlyPayment();
      await ethers.provider.send("evm_increaseTime", [40 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await loanContract.connect(user2).makeMonthlyPayment();

      // User3: Пропуск платежей на 61 день и ликвидация
      await ethers.provider.send("evm_increaseTime", [61 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await loanContract.connect(owner).liquidate(user3.address);

      // Проверки
      const loan1 = await loanContract.getLoanDetails(user1.address);
      const loan2 = await loanContract.getLoanDetails(user2.address);
      const loan3 = await loanContract.getLoanDetails(user3.address);

      expect(loan1.paymentsMade).to.equal(6);
      expect(loan1.active).to.be.true;
      expect(loan2.paymentsMade).to.equal(2);
      expect(loan2.active).to.be.true;
      expect(loan3.active).to.be.false;
    });
  });
});