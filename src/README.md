# Sample Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a Hardhat Ignition module that deploys that contract.

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat ignition deploy ./ignition/modules/Lock.js
```
root is 'src':

```shell
npx hardhat clean
```

Компиляция всех контрактов из contracts
```shell
npx hardhat compile 
```

Тестирование всех контрактов из contracts
```shell
npx hardhat test
```

##Remix run:

Перенести контракты (2) в contracts
Переходим в компилятор:
    Compile CollateralizedLoan.sol
    Compile MockERC20.sol" для компиляции тестового токена
Перейти в деплой:
Деплой контракта MockERC20
Поскольку CollateralizedLoan требует токен ERC20, сначала нужно задеплоить MockERC20.

Перейдите на вкладку "Deploy & Run Transactions" (иконка с стрелкой вправо) в левой панели.
 1. Выбрать акаунт, который публикует контракт (в списке)
 2. В разделе "Contract" выберите MockERC20.
 3. Деплой контракта Moc - Введите параметры конструктора:
     name: "TestToken" (название токена).
     symbol: "TT" (символ токена).
     initialSupply: 1000000000000000000000 (1e18, что равно 1000 токенов, если decimals=18).
4. Деплой контракта CollateralizedLoan - Введите параметры конструктора:
      _interestRate: 500 (5% годовых в базисных пунктах, где 10000 = 100%).
      _penaltyRatePerDay: 100 (1% штрафа в день в базисных пунктах).
      _loanDurationMonths: 12 (12 месяцев).
      _minLoanAmount: 1000000000000000000 (1 токен в wei, 1e18).
5. Настройка разрешенных токенов
   (Контракт CollateralizedLoan требует, чтобы токен был добавлен в список разрешенных через функцию setTokenAllowed.)
    В разделе "Deployed Contracts" найдите экземпляр CollateralizedLoan.
    Раскройте его и найдите функцию setTokenAllowed.
    Введите:
    _token: адрес задеплоенного MockERC20 (скопированный ранее).
    _allowed: true.
    Убедитесь, что транзакция прошла успешно (проверьте логи внизу).
6. Тестирование функции borrow
      Теперь протестируем запрос займа.

    Переключитесь на другой аккаунт:
    В разделе "Account" выберите другой адрес из списка (например, второй аккаунт в JavaScript VM).
    Убедитесь, что у владельца токена MockERC20 есть токены, и он одобрил их для контракта CollateralizedLoan:
    Перейдите к экземпляру MockERC20 в "Deployed Contracts".
    Вызовите функцию approve, указав:
    spender: адрес CollateralizedLoan.
    amount: 1000000000000000000000 (1000 токенов).
    Нажмите "transact" от имени первого аккаунта (владельца токенов).
    Вернитесь к CollateralizedLoan, найдите функцию borrow.
    Введите параметры:
    _token: адрес MockERC20.
    _amount: 1000000000000000000 (1 токен).
    В поле "Value" укажите сумму ETH для залога, например, 1500000000000000000 (1.5 ETH в wei).
    Нажмите "transact" от имени второго аккаунта (заемщика).
    Проверьте, что займ создан:
    Найдите функцию getLoanDetails.
    Введите адрес заемщика (второй аккаунт) и нажмите "call".
    Убедитесь, что данные займа отображаются корректно.