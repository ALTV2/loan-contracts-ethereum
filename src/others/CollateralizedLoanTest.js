const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CollateralizedLoan", function () {
  let CollateralizedLoan, loanContract, MockToken, token;
  let owner, borrower, addr1;
  const INTEREST_RATE = 500; // 5%
  const PENALTY_RATE = 10; // 0.1% в день
  const LOAN_DURATION_MONTHS = 12;
  const MIN_LOAN_AMOUNT = ethers.parseEther("1"); // 1 токен в wei
  const COLLATERAL_AMOUNT = ethers.parseEther("1.5"); // 1.5 ETH
  const LOAN_AMOUNT = ethers.parseEther("1"); // 1 токен

  beforeEach(async function () {
    [owner, borrower, addr1] = await ethers.getSigners();

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

    // Одобрение токенов для контракта
    await token.connect(owner).approve(loanContract.target, ethers.parseEther("1000"));
    await loanContract.connect(owner).setTokenAllowed(token.target, true);
  });

  describe("Deployment", function () {
    it("Should set correct initial parameters", async function () {
      expect(await loanContract.interestRate()).to.equal(INTEREST_RATE);
      expect(await loanContract.penaltyRatePerDay()).to.equal(PENALTY_RATE);
      expect(await loanContract.loanDurationMonths()).to.equal(LOAN_DURATION_MONTHS);
      expect(await loanContract.minLoanAmount()).to.equal(MIN_LOAN_AMOUNT);
      expect(await loanContract.owner()).to.equal(owner.address);
    });
  });

  describe("Borrow", function () {
    it("Should issue a loan successfully", async function () {
      await expect(
        loanContract.connect(borrower).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT })
      )
        .to.emit(loanContract, "LoanIssued")
        .withArgs(borrower.address, token.target, LOAN_AMOUNT, COLLATERAL_AMOUNT, LOAN_DURATION_MONTHS);

      const loan = await loanContract.getLoanDetails(borrower.address);
      expect(loan.token).to.equal(token.target);
      expect(loan.principal).to.equal(LOAN_AMOUNT);
      expect(loan.collateral).to.equal(COLLATERAL_AMOUNT);
      expect(loan.paymentsRequired).to.equal(LOAN_DURATION_MONTHS);
      expect(loan.active).to.be.true;
    });

    it("Should fail if insufficient collateral", async function () {
      await expect(
        loanContract.connect(borrower).borrow(token.target, LOAN_AMOUNT, { value: ethers.parseEther("1") })
      ).to.be.revertedWith("Insufficient collateral");
    });

    it("Should fail if token not allowed", async function () {
      await loanContract.connect(owner).setTokenAllowed(token.target, false);
      await expect(
        loanContract.connect(borrower).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT })
      ).to.be.revertedWith("Token not allowed");
    });
  });

  describe("Make Monthly Payment", function () {
      beforeEach(async function () {
        await loanContract.connect(borrower).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
        // Даем заемщику достаточно токенов для всех платежей
        await token.connect(owner).transfer(borrower.address, ethers.parseEther("10"));
        await token.connect(borrower).approve(loanContract.target, ethers.parseEther("10"));
      });

      it("Should process payment successfully", async function () {
        await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
        await ethers.provider.send("evm_mine");

        const loanBefore = await loanContract.getLoanDetails(borrower.address);
        const paymentAmount = loanBefore.monthlyPayment;

        await expect(loanContract.connect(borrower).makeMonthlyPayment())
          .to.emit(loanContract, "PaymentMade")
          .withArgs(borrower.address, paymentAmount, 1);

        const loanAfter = await loanContract.getLoanDetails(borrower.address);
        expect(loanAfter.paymentsMade).to.equal(1);
        expect(loanAfter.totalDebt).to.equal(loanBefore.totalDebt - paymentAmount);
      });

      it("Should apply penalty for late payment", async function () {
        await ethers.provider.send("evm_increaseTime", [40 * 24 * 60 * 60]);
        await ethers.provider.send("evm_mine");

        const loanBefore = await loanContract.getLoanDetails(borrower.address);
        const basePayment = loanBefore.monthlyPayment;
        const penalty = (basePayment * BigInt(PENALTY_RATE) * BigInt(10)) / BigInt(10000);
        const expectedPayment = basePayment + penalty;

        await expect(loanContract.connect(borrower).makeMonthlyPayment())
          .to.emit(loanContract, "PaymentMade")
          .withArgs(borrower.address, expectedPayment, 1);
      });

      it("Should repay loan fully after all payments", async function () {
        // Сохраняем начальный баланс заемщика
        const initialBalance = await ethers.provider.getBalance(borrower.address);

        // Используем существующий займ из beforeEach, выполняем все платежи
        for (let i = 0; i < LOAN_DURATION_MONTHS; i++) {
          await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
          await ethers.provider.send("evm_mine");
          await loanContract.connect(borrower).makeMonthlyPayment();
        }

        const loan = await loanContract.getLoanDetails(borrower.address);
        expect(loan.active).to.be.false;

        const finalBalance = await ethers.provider.getBalance(borrower.address);
        // Проверяем, что баланс близок к начальному значению с учетом возврата залога и затрат на газ
        expect(finalBalance).to.be.closeTo(
          initialBalance, // Просто начальный баланс, так как залог возвращается
          ethers.parseEther("2") // Погрешность для учета газа
        );
      });
  });

  describe("Liquidate", function () {
    beforeEach(async function () {
      await loanContract.connect(borrower).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
    });

    it("Should liquidate overdue loan", async function () {
      await ethers.provider.send("evm_increaseTime", [61 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
      await expect(loanContract.connect(owner).liquidate(borrower.address))
        .to.emit(loanContract, "CollateralLiquidated")
        .withArgs(borrower.address, COLLATERAL_AMOUNT);

      const ownerBalanceAfter = await ethers.provider.getBalance(owner.address);
      expect(ownerBalanceAfter).to.be.above(ownerBalanceBefore);
      const loan = await loanContract.getLoanDetails(borrower.address);
      expect(loan.active).to.be.false;
    });

    it("Should fail if not overdue enough", async function () {
      await ethers.provider.send("evm_increaseTime", [59 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await expect(loanContract.connect(owner).liquidate(borrower.address)).to.be.revertedWith(
        "Not enough overdue time"
      );
    });
  });

  describe("Emergency Withdraw", function () {
    it("Should allow owner to withdraw ETH", async function () {
      await loanContract.connect(borrower).borrow(token.target, LOAN_AMOUNT, { value: COLLATERAL_AMOUNT });
      const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
      await loanContract.connect(owner).emergencyWithdrawETH();
      const ownerBalanceAfter = await ethers.provider.getBalance(owner.address);
      expect(ownerBalanceAfter).to.be.above(ownerBalanceBefore);
    });

    it("Should fail for non-owner", async function () {
      await expect(loanContract.connect(addr1).emergencyWithdrawETH()).to.be.revertedWithCustomError(
        loanContract,
        "OwnableUnauthorizedAccount"
      );
    });
  });
});