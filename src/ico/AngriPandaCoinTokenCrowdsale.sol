pragma solidity ^0.4.11;

import '/src/common/SafeMath.sol';
import '/src/common/lifecycle/Haltable.sol';
import '/src/ico/SolarDaoToken.sol';
import '/src/common/lifecycle/Killable.sol';

/// @title SolarDaoTokenCrowdsale contract - contract for token sales.
contract SolarDaoTokenCrowdsale is Haltable, Killable, SafeMath {

  /// Prefunding goal in USD cents, if the prefunding goal is reached, ico will start
  uint public constant PRE_FUNDING_GOAL = 4e6 * PRICE;

  /// Tokens funding goal in USD cents, if the funding goal is reached, ico will stop
  uint public constant ICO_GOAL = 8e7 * PRICE;

  /// Miminal tokens funding goal in USD cents, if this goal isn't reached during ICO, refund will begin
  uint public constant MIN_ICO_GOAL = 1e7;

  /// Percent of bonus tokens team receives from each investment
  uint public constant TEAM_BONUS_PERCENT = 25;

  /// The token price in USD cents
  uint constant public PRICE = 100;

  /// Duration of the pre-ICO stage
  uint constant public PRE_ICO_DURATION = 5 weeks;

  /// The token we are selling
  SolarDaoToken public token;

  /// tokens will be transfered from this address
  address public multisigWallet;

  /// the UNIX timestamp start date of the crowdsale
  uint public startsAt;

  /// the UNIX timestamp end date of the crowdsale
  uint public endsAt;

  /// the UNIX timestamp start date of the pre invest crowdsale
  uint public preInvestStart;

  /// the number of tokens already sold through this contract
  uint public tokensSold = 0;

  /// How many wei of funding we have raised
  uint public weiRaised = 0;

  /// How many distinct addresses have invested
  uint public investorCount = 0;

  /// How much wei we have returned back to the contract after a failed crowdfund.
  uint public loadedRefund = 0;

  /// How much wei we have given back to investors.
  uint public weiRefunded = 0;

  /// Has this crowdsale been finalized
  bool public finalized;

  /// USD to Ether rate in cents
  uint public exchangeRate;

  /// exchangeRate timestamp
  uint public exchangeRateTimestamp;

  /// External agent that will can change exchange rate
  address public exchangeRateAgent;

  /// How much ETH each address has invested to this crowdsale
  mapping (address => uint256) public investedAmountOf;

  /// How much tokens this crowdsale has credited for each investor address
  mapping (address => uint256) public tokenAmountOf;

  /// Define preICO pricing schedule using milestones.
  struct Milestone {
      // UNIX timestamp when this milestone kicks in
      uint start;
      // UNIX timestamp when this milestone kicks out
      uint end;
      // How many % tokens will add
      uint bonus;
  }

  Milestone[] public milestones;

  /// State machine
  /// Preparing: All contract initialization calls and variables have not been set yet
  /// Prefunding: We have not passed start time yet
  /// Funding: Active crowdsale
  /// Success: Minimum funding goal reached
  /// Failure: Minimum funding goal not reached before ending time
  /// Finalized: The finalized has been called and succesfully executed\
  /// Refunding: Refunds are loaded on the contract for reclaim.
  enum State{Unknown, Preparing, PreFunding, Funding, Success, Failure, Finalized, Refunding}

  /// A new investment was made
  event Invested(address investor, uint weiAmount, uint tokenAmount);
  /// Refund was processed for a contributor
  event Refund(address investor, uint weiAmount);
  /// Crowdsale end time has been changed
  event EndsAtChanged(uint endsAt);
  /// Calculated new price
  event ExchangeRateChanged(uint oldValue, uint newValue);

  /// @dev Modified allowing execution only if the crowdsale is currently running
  modifier inState(State state) {
    require(getState() == state);
    _;
  }

  modifier onlyExchangeRateAgent() {
    require(msg.sender == exchangeRateAgent);
    _;
  }

  /// @dev Constructor
  /// @param _token Solar Dao token address
  /// @param _multisigWallet team wallet
  /// @param _preInvestStart preICO start date
  /// @param _start token ICO start date
  /// @param _end token ICO end date
  function SolarDaoTokenCrowdsale(address _token, address _multisigWallet, uint _preInvestStart, uint _start, uint _end) {
    require(_multisigWallet != 0);
    require(_preInvestStart != 0);
    require(_start != 0);
    require(_end != 0);
    require(_start < _end);
    require(_end > _preInvestStart + PRE_ICO_DURATION);

    token = SolarDaoToken(_token);

    multisigWallet = _multisigWallet;
    startsAt = _start;
    endsAt = _end;
    preInvestStart = _preInvestStart;

    var preIcoBonuses = [uint(100), 80, 70, 60, 50];
    for (uint i = 0; i < preIcoBonuses.length; i++) {
      milestones.push(Milestone(preInvestStart + i * 1 weeks, preInvestStart + (i + 1) * 1 weeks, preIcoBonuses[i]));
    }
    milestones.push(Milestone(startsAt, startsAt + 4 days, 25));
    milestones.push(Milestone(startsAt + 4 days, startsAt + 1 weeks, 20));
    delete preIcoBonuses;

    var icoBonuses = [uint(15), 10, 5];
    for (i = 1; i <= icoBonuses.length; i++) {
      milestones.push(Milestone(startsAt + i * 1 weeks, startsAt + (i + 1) * 1 weeks, icoBonuses[i - 1]));
    }
    delete icoBonuses;
  }

  function() payable {
    buy();
  }

  /// @dev Get the current milestone or bail out if we are not in the milestone periods.
  /// @return Milestone current bonus milestone
  function getCurrentMilestone() private constant returns (Milestone) {
      for (uint i = 0; i < milestones.length; i++) {
        if (milestones[i].start <= now && milestones[i].end > now) {
          return milestones[i];
        }
      }
  }

   /// @dev Make an investment. Crowdsale must be running for one to invest.
   /// @param receiver The Ethereum address who receives the tokens
  function investInternal(address receiver) stopInEmergency private {
    var state = getState();
    require(state == State.Funding || state == State.PreFunding);

    uint weiAmount = msg.value;
    uint tokensAmount = calculateTokens(weiAmount);
    assert (tokensAmount > 0);

    if(state == State.PreFunding) {
        tokensAmount += safeDiv(safeMul(tokensAmount, getCurrentMilestone().bonus), 100);
    }

    if(investedAmountOf[receiver] == 0) {
       // A new investor
       investorCount++;
    }

    // Update investor
    investedAmountOf[receiver] = safeAdd(investedAmountOf[receiver], weiAmount);
    tokenAmountOf[receiver] = safeAdd(tokenAmountOf[receiver], tokensAmount);
    // Update totals
    weiRaised = safeAdd(weiRaised, weiAmount);
    tokensSold = safeAdd(tokensSold, tokensAmount);

    // Check that we did not bust the cap
    /*
    if(isBreakingCap(weiAmount, tokensAmount, weiRaised, tokensSold)) {
      throw;
    }*/

    assignTokens(receiver, tokensAmount);
    var teamBonusTokens = safeDiv(safeMul(tokensAmount, TEAM_BONUS_PERCENT), 100 - TEAM_BONUS_PERCENT);
    assignTokens(multisigWallet, teamBonusTokens);

    multisigWallet.transfer(weiAmount);
    // Tell us invest was success
    Invested(receiver, weiAmount, tokensAmount);
  }

  /// @dev Allow anonymous contributions to this crowdsale.
  /// @param receiver The Ethereum address who receives the tokens
  function invest(address receiver) public payable {
    investInternal(receiver);
  }

  /// @dev The basic entry point to participate the crowdsale process.
  function buy() public payable {
    invest(msg.sender);
  }

  /// @dev Finalize a succcesful crowdsale.
  function finalize() public inState(State.Success) onlyOwner stopInEmergency {
    require(!finalized);

    finalized = true;
    finalizeCrowdsale();
  }

  /// @dev Finalize a succcesful crowdsale.
  function finalizeCrowdsale() internal {
    //assignTokens(owner, safeAdd(safeSub(uint(MAX_TOKENS_TO_SOLD), tokensSold), TEAM_TOKENS_AMOUNT));
    token.releaseTokenTransfer();
  }

   /// @dev Method for setting USD to Ether rate from Poloniex
   /// @param value USD amout in cents for 1 Ether
   /// @param time timestamp
  function setExchangeRate(uint value, uint time) onlyExchangeRateAgent {
    require(value > 0);
    require(time > 0);
    require(exchangeRateTimestamp == 0 || getDifference(int(time), int(now)) <= 1 minutes);
    require(exchangeRate == 0 || (getDifference(int(value), int(exchangeRate)) * 100 / exchangeRate <= 30));

    ExchangeRateChanged(exchangeRate, value);
    exchangeRate = value;
    exchangeRateTimestamp = time;
  }

  /// @dev Method set exchange rate agent
  /// @param newAgent new agent
 function setExchangeRateAgent(address newAgent) onlyOwner {
   if (newAgent != address(0)) {
     exchangeRateAgent = newAgent;
   }
 }

  function getDifference(int one, int two) private constant returns (uint) {
    var diff = one - two;
    if (diff < 0)
      diff = -diff;
    return uint(diff);
  }

  /// @dev Allow crowdsale owner to close early or extend the crowdsale.
  /// @param time timestamp
  function setEndsAt(uint time) onlyOwner {
    require(time >= now);
    endsAt = time;
    EndsAtChanged(endsAt);
  }

  /// @dev Allow load refunds back on the contract for the refunding.
  function loadRefund() public payable inState(State.Failure) {
    require(msg.value > 0);
    loadedRefund = safeAdd(loadedRefund, msg.value);
  }

  /// @dev Investors can claim refund.
  function refund() public inState(State.Refunding) {
    uint256 weiValue = investedAmountOf[msg.sender];
    if (weiValue == 0)
      return;
    investedAmountOf[msg.sender] = 0;
    weiRefunded = safeAdd(weiRefunded, weiValue);
    Refund(msg.sender, weiValue);
    msg.sender.transfer(weiValue);
  }

  /// @dev Minimum goal was reached
  /// @return true if the crowdsale has raised enough money to not initiate the refunding
  function isMinimumGoalReached() public constant returns (bool reached) {
    return weiToUsdCents(weiRaised) >= MIN_ICO_GOAL;
  }

  /// @dev Check if the ICO goal was reached.
  /// @return true if the crowdsale has raised enough money to be a success
  function isCrowdsaleFull() public constant returns (bool) {
    return weiToUsdCents(weiRaised) >= ICO_GOAL;
  }

   /// @dev Method set data from migrated contract
  /// @param _tokensSold tokens sold
  /// @param _weiRaised _wei raised
  /// @param _investorCount investor count
 function setCrowdsaleData(uint _tokensSold, uint _weiRaised, uint _investorCount) onlyOwner {  
	require(_tokensSold > 0);
	require(_weiRaised > 0);
	require(_investorCount > 0);
	
	tokensSold = _tokensSold;
	weiRaised = _weiRaised;
	investorCount = _investorCount;	
 }

  /// @dev Crowdfund state machine management.
  /// @return State current state
  function getState() public constant returns (State) {
    if (finalized)
      return State.Finalized;
    if (address(token) == 0 || address(multisigWallet) == 0 || now < preInvestStart)
      return State.Preparing;
    if (preInvestStart <= now && now < startsAt && !isMaximumPreFundingGoalReached())
      return State.PreFunding;
    if (now <= endsAt && !isCrowdsaleFull())
      return State.Funding;
    if (isMinimumGoalReached())
      return State.Success;
    if (!isMinimumGoalReached() && weiRaised > 0 && loadedRefund >= weiRaised)
      return State.Refunding;
    return State.Failure;
  }

  /// @dev Calculating tokens count
  /// @param weiAmount invested
  /// @return tokens amount
  function calculateTokens(uint weiAmount) internal returns (uint tokenAmount) {
    var multiplier = 10 ** token.decimals();

    uint usdAmount = weiToUsdCents(weiAmount);
    assert (usdAmount >= PRICE);

    return safeMul(usdAmount, safeDiv(multiplier, PRICE));
  }

   /// @dev Check if the current invested breaks our cap rules.
   /// @param weiAmount The amount of wei the investor tries to invest in the current transaction
   /// @param tokenAmount The amount of tokens we try to give to the investor in the current transaction
   /// @param weiRaisedTotal What would be our total raised balance after this transaction
   /// @param tokensSoldTotal What would be our total sold tokens count after this transaction
   /// @return result
   function isBreakingCap(uint weiAmount, uint tokenAmount, uint weiRaisedTotal, uint tokensSoldTotal) constant returns (bool limitBroken) {
     return false;
   }

   /// @dev Check if the pre ICO goal was reached.
   /// @return true if the preICO has raised enough money to be a success
   function isMaximumPreFundingGoalReached() public constant returns (bool reached) {
     return weiToUsdCents(weiRaised) >= PRE_FUNDING_GOAL;
   }

   /// @dev Converts wei value into USD cents according to current exchange rate
   /// @param weiValue wei value to convert
   /// @return USD cents equivalent of the wei value
   function weiToUsdCents(uint weiValue) private returns (uint) {
     return safeDiv(safeMul(weiValue, exchangeRate), 1e18);
   }

   /// @dev Dynamically create tokens and assign them to the investor.
   /// @param receiver investor address
   /// @param tokenAmount The amount of tokens we try to give to the investor in the current transaction
   function assignTokens(address receiver, uint tokenAmount) private {
     token.mint(receiver, tokenAmount);
   }
}
