const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CollateralizedLoan", function () {
  let CollateralizedLoan, MockERC20;
  let loanContract, mockToken;
  let owner, borrower, anotherUser;
  const BASIS_POINTS = 10000;
  const SECONDS_PER_DAY = 86400;
  const DAYS_PER_MONTH = 30;

  beforeEach(async function () {
    [owner, borrower, anotherUser] = await ethers.getSigners();

    // Развертываем мок-токен
    MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20.deploy("MockToken", "MTK", ethers.parseEther("10000"));
    await mockToken.waitForDeployment();

    // Развертываем контракт CollateralizedLoan
    CollateralizedLoan = await ethers.getContractFactory("CollateralizedLoan");
    loanContract = await CollateralizedLoan.deploy(owner.address);
    await loanContract.waitForDeployment();

    // Одобряем токены для контракта от владельца
    await mockToken.approve(loanContract.target, ethers.parseEther("10000"));
  });

  describe("addToken", function () {
    it("should allow owner to add a token with parameters", async function () {
      const priceInWei = ethers.parseUnits("0.0005", 18); // 1 токен = 0.0005 ETH
      const interestRate = 1000; // 10%
      const penaltyRate = 50; // 0.5% в день

      await expect(loanContract.addToken(mockToken.target, priceInWei, interestRate, penaltyRate))
        .to.emit(loanContract, "TokenPriceUpdated")
        .withArgs(mockToken.target, priceInWei);

      const tokenInfo = await loanContract.tokenInfo(mockToken.target);
      expect(tokenInfo.allowed).to.be.true;
      expect(tokenInfo.priceInWei).to.equal(priceInWei);
      expect(tokenInfo.interestRate).to.equal(interestRate);
      expect(tokenInfo.penaltyRatePerDay).to.equal(penaltyRate);
    });

    it("should revert if not owner tries to add token", async function () {
      await expect(
        loanContract.connect(borrower).addToken(mockToken.target, ethers.parseEther("1"), 1000, 50)
      ).to.be.revertedWithCustomError(loanContract, "OwnableUnauthorizedAccount");
    });

    it("should revert if price is zero", async function () {
      await expect(loanContract.addToken(mockToken.target, 0, 1000, 50)).to.be.revertedWith(
        "Price must be greater than 0"
      );
    });
  });

  describe("updateTokenParams", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseEther("1"), 1000, 50);
    });

    it("should allow owner to update token parameters", async function () {
      const newPrice = ethers.parseEther("2");
      await expect(loanContract.updateTokenParams(mockToken.target, newPrice, 2000, 100))
        .to.emit(loanContract, "TokenPriceUpdated")
        .withArgs(mockToken.target, newPrice);

      const tokenInfo = await loanContract.tokenInfo(mockToken.target);
      expect(tokenInfo.priceInWei).to.equal(newPrice);
      expect(tokenInfo.interestRate).to.equal(2000);
      expect(tokenInfo.penaltyRatePerDay).to.equal(100);
    });

    it("should revert if token not allowed", async function () {
      await expect(
        loanContract.updateTokenParams(anotherUser.address, ethers.parseEther("1"), 1000, 50)
      ).to.be.revertedWith("Token not allowed");
    });
  });

  describe("depositTokens", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseEther("1"), 1000, 50);
    });

    it("should allow owner to deposit tokens", async function () {
      const amount = ethers.parseEther("1000");
      await loanContract.depositTokens(mockToken.target, amount);
      expect(await mockToken.balanceOf(loanContract.target)).to.equal(amount);
    });

    it("should revert if token not allowed", async function () {
      await expect(
        loanContract.depositTokens(anotherUser.address, ethers.parseEther("100"))
      ).to.be.revertedWith("Token not allowed");
    });

    it("should revert if transfer fails due to insufficient allowance", async function () {
      await mockToken.approve(loanContract.target, 0); // Отзываем одобрение
      await expect(
        loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"))
      ).to.be.revertedWith("ERC20: insufficient allowance"); // Ожидаем ошибку токена
    });
  });

  describe("borrow", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseUnits("0.0005", 18), 1000, 50);
      await loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"));
    });

    it("should allow borrowing with correct collateral", async function () {
      const amount = ethers.parseEther("200"); // 200 токенов = 0.1 ETH (мин. сумма)
      const duration = 12;
      const loanValueInETH = (amount * ethers.parseUnits("0.0005", 18)) / ethers.parseEther("1");
      const minCollateral = (loanValueInETH * 13000n) / 10000n;

      await expect(
        loanContract.connect(borrower).borrow(mockToken.target, amount, duration, { value: minCollateral })
      )
        .to.emit(loanContract, "LoanIssued")
        .withArgs(borrower.address, mockToken.target, amount, minCollateral, duration);

      const loan = await loanContract.loans(borrower.address);
      expect(loan.active).to.be.true;
      expect(loan.principal).to.equal(amount);
      expect(loan.collateral).to.equal(minCollateral);
      expect(await mockToken.balanceOf(borrower.address)).to.equal(amount);
    });

    it("should revert if insufficient collateral", async function () {
      const amount = ethers.parseEther("200");
      await expect(
        loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: ethers.parseEther("0.01") })
      ).to.be.revertedWith("Insufficient collateral");
    });

    it("should revert if loan amount below minimum", async function () {
      const amount = ethers.parseEther("100"); // 0.05 ETH < 0.1 ETH
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await expect(
        loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral })
      ).to.be.revertedWith("Amount below minimum in ETH");
    });

    it("should revert if active loan exists", async function () {
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral });
      await expect(
        loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral })
      ).to.be.revertedWith("Active loan exists");
    });

    it("should revert if token transfer fails", async function () {
      await mockToken.approve(loanContract.target, 0); // Отзываем одобрение
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await expect(
        loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral })
      ).to.be.revertedWith("Token transfer failed");
    });
  });

  describe("makeMonthlyPayment", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseUnits("0.0005", 18), 1000, 50);
      await loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"));
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral });
      await mockToken.connect(borrower).approve(loanContract.target, ethers.parseEther("1000"));
    });

    it("should process monthly payment without penalty", async function () {
      await ethers.provider.send("evm_increaseTime", [DAYS_PER_MONTH * SECONDS_PER_DAY]);
      await ethers.provider.send("evm_mine");

      const loanBefore = await loanContract.loans(borrower.address);
      const paymentAmount = loanBefore.monthlyPayment;

      await expect(loanContract.connect(borrower).makeMonthlyPayment())
        .to.emit(loanContract, "PaymentMade")
        .withArgs(borrower.address, paymentAmount, 1);

      const loanAfter = await loanContract.loans(borrower.address);
      expect(loanAfter.paymentsMade).to.equal(1);
      expect(loanAfter.totalDebt).to.equal(loanBefore.totalDebt - paymentAmount);
    });

    it("should process payment with penalty if overdue", async function () {
      await ethers.provider.send("evm_increaseTime", [DAYS_PER_MONTH * SECONDS_PER_DAY + 5 * SECONDS_PER_DAY]);
      await ethers.provider.send("evm_mine");

      const loanBefore = await loanContract.loans(borrower.address);
      const penalty = (loanBefore.totalDebt * 50n * 5n) / 10000n;
      const expectedPayment = loanBefore.monthlyPayment + penalty;

      await expect(loanContract.connect(borrower).makeMonthlyPayment())
        .to.emit(loanContract, "PaymentMade")
        .withArgs(borrower.address, expectedPayment, 1);
    });

    it("should fully repay loan after all payments", async function () {
      for (let i = 0; i < 12; i++) {
        await ethers.provider.send("evm_increaseTime", [DAYS_PER_MONTH * SECONDS_PER_DAY]);
        await ethers.provider.send("evm_mine");
        await loanContract.connect(borrower).makeMonthlyPayment();
      }

      const loan = await loanContract.loans(borrower.address);
      expect(loan.active).to.be.false;
      expect(loan.totalDebt).to.be.lte(0);
    });
  });

  describe("repayEarly", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseUnits("0.0005", 18), 1000, 50);
      await loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"));
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral });
      await mockToken.connect(borrower).approve(loanContract.target, ethers.parseEther("1000"));
    });

    it("should allow early repayment without penalty", async function () {
      const loanBefore = await loanContract.loans(borrower.address);
      await expect(loanContract.connect(borrower).repayEarly())
        .to.emit(loanContract, "EarlyRepayment")
        .withArgs(borrower.address, loanBefore.totalDebt);

      const loanAfter = await loanContract.loans(borrower.address);
      expect(loanAfter.active).to.be.false;
    });

    it("should include penalty if overdue", async function () {
      await ethers.provider.send("evm_increaseTime", [DAYS_PER_MONTH * SECONDS_PER_DAY + 5 * SECONDS_PER_DAY]);
      await ethers.provider.send("evm_mine");

      const loanBefore = await loanContract.loans(borrower.address);
      const penalty = (loanBefore.totalDebt * 50n * 5n) / 10000n;
      const expectedPayment = loanBefore.totalDebt + penalty;

      await expect(loanContract.connect(borrower).repayEarly())
        .to.emit(loanContract, "EarlyRepayment")
        .withArgs(borrower.address, expectedPayment);
    });
  });

  describe("liquidateLoan", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseUnits("0.0005", 18), 1000, 50);
      await loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"));
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral });
    });

    it("should liquidate overdue loan", async function () {
      await ethers.provider.send("evm_increaseTime", [61 * SECONDS_PER_DAY]);
      await ethers.provider.send("evm_mine");

      await expect(loanContract.liquidateLoan(borrower.address))
        .to.emit(loanContract, "LoanLiquidated")
        .withArgs(borrower.address, (await loanContract.loans(borrower.address)).collateral);

      const loan = await loanContract.loans(borrower.address);
      expect(loan.active).to.be.false;
      expect(await loanContract.liquidatedCollateral()).to.equal(loan.collateral);
    });

    it("should revert if not overdue enough", async function () {
      await expect(loanContract.liquidateLoan(borrower.address)).to.be.revertedWith("Not overdue enough");
    });
  });

  describe("emergencyWithdrawETH", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseUnits("0.0005", 18), 1000, 50);
      await loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"));
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral });
    });

    it("should withdraw liquidated collateral after liquidation", async function () {
      await ethers.provider.send("evm_increaseTime", [61 * SECONDS_PER_DAY]);
      await ethers.provider.send("evm_mine");
      await loanContract.liquidateLoan(borrower.address);

      const liquidated = await loanContract.liquidatedCollateral();
      await expect(loanContract.emergencyWithdrawETH())
        .to.emit(loanContract, "EmergencyWithdrawETH")
        .withArgs(liquidated);

      expect(await loanContract.liquidatedCollateral()).to.equal(0);
    });

    it("should revert if no liquidated ETH", async function () {
      await expect(loanContract.emergencyWithdrawETH()).to.be.revertedWith("No free ETH to withdraw");
    });
  });

  describe("updateParameters", function () {
    it("should allow owner to update global parameters", async function () {
      await loanContract.updateParameters(15000, 2, ethers.parseEther("0.2"));
      expect(await loanContract.minCollateralRatio()).to.equal(15000);
      expect(await loanContract.minLoanDurationMonths()).to.equal(2);
      expect(await loanContract.minLoanAmountInETH()).to.equal(ethers.parseEther("0.2"));
    });
  });

  describe("getLoanDetails and getTokenLoanParams", function () {
    beforeEach(async function () {
      await loanContract.addToken(mockToken.target, ethers.parseUnits("0.0005", 18), 1000, 50);
      await loanContract.depositTokens(mockToken.target, ethers.parseEther("1000"));
      const amount = ethers.parseEther("200");
      const minCollateral = (amount * ethers.parseUnits("0.0005", 18) * 13000n) / (10000n * ethers.parseEther("1"));
      await loanContract.connect(borrower).borrow(mockToken.target, amount, 12, { value: minCollateral });
    });

    it("should return correct loan details", async function () {
      const [token, principal, collateral, totalDebt, monthlyPayment, nextPaymentDue, paymentsMade, paymentsRequired, active] =
        await loanContract.getLoanDetails(borrower.address);

      expect(token).to.equal(mockToken.target);
      expect(principal).to.equal(ethers.parseEther("200"));
      expect(active).to.be.true;
    });

    it("should return correct token parameters", async function () {
      const [allowed, priceInWei, interestRate, penaltyRatePerDay] = await loanContract.getTokenLoanParams(mockToken.target);
      expect(allowed).to.be.true;
      expect(priceInWei).to.equal(ethers.parseUnits("0.0005", 18));
      expect(interestRate).to.equal(1000);
      expect(penaltyRatePerDay).to.equal(50);
    });
  });
});