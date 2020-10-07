# @version 0.2.4

# @dev Implementation of ERC-20 token standard.
# @author Takayuki Jimba (@yudetamago)
# https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20.md

from vyper.interfaces import ERC20


interface VotingEscrow:
    def locked(_account: address) -> (int128, uint256): view
    def balanceOf(_account: address) -> uint256: view
    def create_lock(_value: uint256, _unlock_time: uint256): nonpayable
    def increase_amount(_value: uint256): nonpayable
    def increase_unlock_time(_unlock_time: uint256): nonpayable
    def withdraw(): nonpayable


interface Gauge:
    def lp_token() -> address: view
    def deposit(_value: uint256): nonpayable
    def withdraw(_value: uint256): nonpayable


interface Minter:
    def mint(_gauge: address): nonpayable


implements: ERC20

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowances: HashMap[address, HashMap[address, uint256]]
total_supply: uint256
minter: address

WEEK: constant(uint256) = 7 * 86400  # all future times are rounded by week
MAXTIME: constant(uint256) = 4 * 365 * 86400  # 4 years
swrv: ERC20
voting_escrow: VotingEscrow
swrv_minter: Minter
# gauge -> user -> balance
gauge_balances: public(HashMap[address, HashMap[address, uint256]])


@external
def __init__():
    self.name = "Liquid veSWRV"
    self.symbol = "UNSWRV"
    self.decimals = 18
    self.minter = self

    self.swrv_minter = Minter(0x2c988c3974AD7E604E276AE0294a7228DEf67974)
    self.swrv = ERC20(0xB8BAa0e4287890a5F79863aB62b7F175ceCbD433)
    self.swrv.approve(self.voting_escrow.address, MAX_UINT256)


@view
@external
def totalSupply() -> uint256:
    """
    @dev Total number of tokens in existence.
    """
    return self.total_supply


@view
@external
def allowance(_owner : address, _spender : address) -> uint256:
    """
    @dev Function to check the amount of tokens that an owner allowed to a spender.
    @param _owner The address which owns the funds.
    @param _spender The address which will spend the funds.
    @return An uint256 specifying the amount of tokens still available for the spender.
    """
    return self.allowances[_owner][_spender]


@external
def transfer(_to : address, _value : uint256) -> bool:
    """
    @dev Transfer token for a specified address
    @param _to The address to transfer to.
    @param _value The amount to be transferred.
    """
    # NOTE: vyper does not allow underflows
    #       so the following subtraction would revert on insufficient balance
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value
    log Transfer(msg.sender, _to, _value)
    return True


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    """
     @dev Transfer tokens from one address to another.
     @param _from address The address which you want to send tokens from
     @param _to address The address which you want to transfer to
     @param _value uint256 the amount of tokens to be transferred
    """
    # NOTE: vyper does not allow underflows
    #       so the following subtraction would revert on insufficient balance
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    # NOTE: vyper does not allow underflows
    #      so the following subtraction would revert on insufficient allowance
    self.allowances[_from][msg.sender] -= _value
    log Transfer(_from, _to, _value)
    return True


@external
def approve(_spender : address, _value : uint256) -> bool:
    """
    @dev Approve the passed address to spend the specified amount of tokens on behalf of msg.sender.
         Beware that changing an allowance with this method brings the risk that someone may use both the old
         and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
         race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
         https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender The address which will spend the funds.
    @param _value The amount of tokens to be spent.
    """
    self.allowances[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True


@internal
def _mint(_to: address, _value: uint256):
    """
    @dev Mint an amount of the token and assigns it to an account.
         This encapsulates the modification of balances such that the
         proper events are emitted.
    @param _to The account that will receive the created tokens.
    @param _value The amount that will be created.
    """
    assert _to != ZERO_ADDRESS
    self.total_supply += _value
    self.balanceOf[_to] += _value
    log Transfer(ZERO_ADDRESS, _to, _value)


@internal
def _burn(_to: address, _value: uint256):
    """
    @dev Internal function that burns an amount of the token of a given
         account.
    @param _to The account whose tokens will be burned.
    @param _value The amount that will be burned.
    """
    assert _to != ZERO_ADDRESS
    self.total_supply -= _value
    self.balanceOf[_to] -= _value
    log Transfer(_to, ZERO_ADDRESS, _value)

# Voting Escrow methods

@external
def deposit(_value: uint256):
    """
    @dev Deposit SWRV into Voting Escrow and get a 1:1 liquid claim on veSWRV.
    """
    self.swrv.transferFrom(msg.sender, self, _value)

    amount: int128 = 0
    end: uint256 = 0
    amount, end = self.voting_escrow.locked(self)

    if end == 0:
        self.voting_escrow.create_lock(_value, block.timestamp + MAXTIME)
    else:
        self.voting_escrow.increase_amount(_value)

    self._mint(msg.sender, _value)


@external
def withdraw():
    """
    @dev Reclaim SWRV from Voting Escrow after vote lock has expired.
    """
    locked: int128 = 0
    end: uint256 = 0
    locked, end = self.voting_escrow.locked(self)
    
    if block.timestamp >= end and locked != 0:
        self.voting_escrow.withdraw()
    
    amount: uint256 = self.balanceOf[msg.sender]
    self._burn(msg.sender, amount)
    self.swrv.transfer(msg.sender, amount)

# Gauge methods

@external
def gauge_deposit(_gauge: address, _value: uint256):
    """
    @dev Deposit LP token (e.g. SWUSD) into Liquidity Gauge.
    """
    lp_token: address = Gauge(_gauge).lp_token()
    ERC20(lp_token).transferFrom(msg.sender, self, _value)
    Gauge(_gauge).deposit(_value)
    self.gauge_balances[_gauge][msg.sender] += _value


@external
def gauge_withdraw(_gauge: address, _value: uint256):
    """
    @dev Withdraw LP token (e.g. SWUSD) from Liquidity Gauge.
    """
    lp_token: address = Gauge(_gauge).lp_token()
    Gauge(_gauge).withdraw(_value)
    self.gauge_balances[_gauge][msg.sender] -= _value
    ERC20(lp_token).transfer(msg.sender, _value)

# Minter methods

@external
def gauge_mint(_gauge: address):
    self.swrv_minter.mint(_gauge)
    # TODO: split rewards
    self.voting_escrow.increase_amount(self.swrv.balanceOf(self))
