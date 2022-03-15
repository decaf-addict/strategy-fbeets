import pytest
from brownie import config
from brownie import Contract


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0xfcef8a994209d6916EB2C86cDD2AFD60Aa6F54b1"  # fBeets
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 1_000_000 * 10 ** token.decimals()

    reserve = accounts.at("0x8166994d9ebBe5829EC86Bd81258149B87faCfd3", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def masterchef():
    yield Contract("0x8166994d9ebBe5829EC86Bd81258149B87faCfd3")


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def balancer_vault():
    yield Contract("0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce")


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, balancer_vault, masterchef, chain):
    strategy = strategist.deploy(Strategy, vault, balancer_vault, masterchef, 22)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    chain.sleep(1)
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
