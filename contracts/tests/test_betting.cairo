#[cfg(test)]
mod tests {
    use starknet::{
        ContractAddress,
        testing::set_block_timestamp,
        get_caller_address,
        contract_address_const,
        class_hash::Felt252TryIntoClassHash
    };
    use snforge_std::{
        declare, start_prank, stop_prank, start_mock_call, stop_mock_call,
        ContractClassTrait, CheatTarget,
        assert_eq, assert_ne,
        test_utils
    };
    use traits::TryInto;
    use array::ArrayTrait;
    use option::OptionTrait;
    use debug::PrintTrait;
    use result::ResultTrait;

    use brother_betting::interfaces::{
        IBettingGame,
        IBettingGameDispatcher,
        IBettingGameDispatcherTrait,
        IERC20,
        IERC20Dispatcher,
        IERC20DispatcherTrait,
        Bet,
        BetsSummary
    };

    // Constants
    const INITIAL_BALANCE: felt252 = 1000000000000000000000; // 1000 tokens
    const CANCEL_DELAY: u64 = 86400_u64; // 24 hours in seconds

    // Test setup
    fn setup() -> (ContractAddress, IBettingGameDispatcher, IERC20Dispatcher) {
        // Deploy mock ERC20 token
        let erc20_class = declare('ERC20');
        let mut calldata = ArrayTrait::new();
        calldata.append('Test Token');
        calldata.append('TST');
        calldata.append(18);
        calldata.append(INITIAL_BALANCE);
        let _salt = contract_address_const::<123>();
        let token_address = erc20_class.deploy(@calldata).unwrap();
        let token = IERC20Dispatcher { contract_address: token_address };

        // Deploy betting game contract
        let betting_class = declare('BettingGame');
        let mut constructor_calldata = ArrayTrait::new();
        constructor_calldata.append(token_address.into());
        let _salt2 = contract_address_const::<456>();
        let contract_address = betting_class.deploy(@constructor_calldata).unwrap();
        let betting_game = IBettingGameDispatcher { contract_address };

        (token_address, betting_game, token)
    }

    #[test]
    fn test_create_bet() {
        let (token_address, betting_game, _token) = setup();
        let caller = contract_address_const::<1>();
        let amount: u256 = 100000000000000000000_u256; // 100 tokens
        
        // Start pranking as caller
        start_prank(CheatTarget::One(betting_game.contract_address), caller);
        
        // Mock token approval
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        
        // Create bet
        let odds: u32 = 2_u32;
        let bet_id = betting_game.create_bet(odds, amount);
        
        // Verify bet details
        let (bet, is_active) = betting_game.get_bet(bet_id);
        assert(is_active, 'Bet should be active');
        assert(bet.proposer == caller, 'Wrong proposer');
        assert(bet.proposer_amount == amount, 'Wrong amount');
        assert(bet.odds == odds, 'Wrong odds');
        assert(bet.responder.is_zero(), 'Should have no responder');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }

    #[test]
    fn test_create_bet_invalid_odds() {
        let (token_address, betting_game, _token) = setup();
        let caller = contract_address_const::<1>();
        
        start_prank(CheatTarget::One(betting_game.contract_address), caller);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        
        // This should panic with 'Invalid odds'
        let result = betting_game.create_bet(4_u32, 100000000000000000000_u256);
        assert(result.is_err(), 'Should panic with invalid odds');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }

    #[test]
    fn test_match_bet() {
        let (token_address, betting_game, _token) = setup();
        let proposer = contract_address_const::<1>();
        let responder = contract_address_const::<2>();
        let amount: u256 = 100000000000000000000_u256;
        
        // Create bet
        start_prank(CheatTarget::One(betting_game.contract_address), proposer);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        let bet_id = betting_game.create_bet(2_u32, amount);
        stop_prank(CheatTarget::One(betting_game.contract_address));
        
        // Match bet
        start_prank(CheatTarget::One(betting_game.contract_address), responder);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        start_mock_call(token_address, selector!("transfer"), array![true]);
        
        // Set timestamp to ensure deterministic outcome
        set_block_timestamp(1000);
        betting_game.match_bet(bet_id, amount);
        
        // Verify bet is no longer active
        let (bet, is_active) = betting_game.get_bet(bet_id);
        assert(!is_active, 'Bet should not be active');
        assert(bet.responder == responder, 'Wrong responder');
        assert(bet.responder_amount == amount, 'Wrong responder amount');
        assert(!bet.winner.is_zero(), 'Winner should be set');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }

    #[test]
    fn test_cancel_bet() {
        let (token_address, betting_game, _token) = setup();
        let proposer = contract_address_const::<1>();
        let amount: u256 = 100000000000000000000_u256;
        
        start_prank(CheatTarget::One(betting_game.contract_address), proposer);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        let bet_id = betting_game.create_bet(2_u32, amount);
        
        // Set timestamp after cancel delay
        set_block_timestamp(CANCEL_DELAY + 1);
        
        // Mock token transfer for refund
        start_mock_call(token_address, selector!("transfer"), array![true]);
        
        betting_game.cancel_bet(bet_id);
        
        // Verify bet is cancelled
        let (_, is_active) = betting_game.get_bet(bet_id);
        assert(!is_active, 'Bet should not be active');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }

    #[test]
    fn test_cancel_bet_too_early() {
        let (token_address, betting_game, _token) = setup();
        let proposer = contract_address_const::<1>();
        
        start_prank(CheatTarget::One(betting_game.contract_address), proposer);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        
        let bet_id = betting_game.create_bet(2_u32, 100000000000000000000_u256);
        
        // Try to cancel immediately - should fail
        let result = betting_game.cancel_bet(bet_id);
        assert(result.is_err(), 'Should not be able to cancel early');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }

    #[test]
    fn test_get_bets_by_odds() {
        let (token_address, betting_game, _token) = setup();
        let proposer = contract_address_const::<1>();
        let amount: u256 = 100000000000000000000_u256;
        
        start_prank(CheatTarget::One(betting_game.contract_address), proposer);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        
        // Create multiple bets with different odds
        betting_game.create_bet(2_u32, amount);
        betting_game.create_bet(2_u32, amount);
        betting_game.create_bet(3_u32, amount);
        
        // Get bets with odds = 2
        let bets: Array<Bet> = betting_game.get_bets_by_odds(2_u32);
        assert(bets.len() == 2_u32, 'Should have 2 bets');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }

    #[test]
    fn test_fee_collection() {
        let (token_address, betting_game, _token) = setup();
        let proposer = contract_address_const::<1>();
        let responder = contract_address_const::<2>();
        let amount: u256 = 100000000000000000000_u256;
        
        // Create and match bet
        start_prank(CheatTarget::One(betting_game.contract_address), proposer);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        let bet_id = betting_game.create_bet(2_u32, amount);
        stop_prank(CheatTarget::One(betting_game.contract_address));
        
        start_prank(CheatTarget::One(betting_game.contract_address), responder);
        start_mock_call(token_address, selector!("transfer_from"), array![true]);
        start_mock_call(token_address, selector!("transfer"), array![true]);
        betting_game.match_bet(bet_id, amount);
        
        // Verify collected fees
        let total_fees = betting_game.get_total_fees();
        let expected_fees = (amount * 2_u256 * 1_u256) / 100_u256; // 1% of total pot
        assert(total_fees == expected_fees, 'Wrong fee amount');
        
        stop_prank(CheatTarget::One(betting_game.contract_address));
    }
}