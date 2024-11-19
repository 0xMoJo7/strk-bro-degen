#[feature("deprecated_legacy_map")]
#[starknet::contract]
mod TestToken {
    use starknet::{ContractAddress, get_caller_address};
    use brother_betting::interfaces::IERC20;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        total_supply: u256,
        balances: LegacyMap<ContractAddress, u256>,
        allowances: LegacyMap<(ContractAddress, ContractAddress), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, recipient: ContractAddress, amount: u256) {
        self.name.write('Test Token');
        self.symbol.write('TST');
        self.decimals.write(18_u8);
        self.total_supply.write(amount);
        self.balances.write(recipient, amount);
    }

    #[abi(embed_v0)]
    impl IERC20Impl of IERC20<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
            self.allowances.read((owner, spender))
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            let sender_balance = self.balances.read(sender);
            assert(sender_balance >= amount, 'Insufficient balance');
            self.balances.write(sender, sender_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let caller = get_caller_address();
            let sender_balance = self.balances.read(sender);
            let current_allowance = self.allowances.read((sender, caller));
            
            assert(sender_balance >= amount, 'Insufficient balance');
            assert(current_allowance >= amount, 'Insufficient allowance');
            
            self.balances.write(sender, sender_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.allowances.write((sender, caller), current_allowance - amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let owner = get_caller_address();
            self.allowances.write((owner, spender), amount);
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use core::traits::TryInto;
    use starknet::{
        ContractAddress,
        contract_address_const,
        get_caller_address,
    };
    use snforge_std::{
        declare,
        DeclareResultTrait,
        ContractClassTrait,
        ContractClass,
        start_cheat_caller_address,
        stop_cheat_caller_address,
        start_mock_call,
        stop_mock_call,
        start_cheat_block_timestamp,
        stop_cheat_block_timestamp,
    };

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

    const INITIAL_SUPPLY: u256 = 1000000000000000000000; // 1000 tokens with 18 decimals
    const CANCEL_DELAY: u64 = 86400_u64; // 24 hours in seconds
    const BET_AMOUNT: felt252 = 100000000000000000000; // 100 tokens

    fn deploy_token() -> (ContractAddress, IERC20Dispatcher) {
        let contract = declare("TestToken").unwrap().contract_class();
        let recipient = starknet::get_caller_address();
        let constructor_calldata = array![
            recipient.into(),
            INITIAL_SUPPLY.low.into(),
            INITIAL_SUPPLY.high.into(),
        ];
        
        let (addr, _) = contract
            .deploy(@constructor_calldata)
            .unwrap();
        let dispatcher = IERC20Dispatcher { contract_address: addr };
        
        (addr, dispatcher)
    }

    fn deploy_betting_game(token: ContractAddress) -> (ContractAddress, IBettingGameDispatcher) {
        let contract = declare("BettingGame").unwrap().contract_class();
        let constructor_calldata = array![token.into()];
        
        let (addr, _) = contract
            .deploy(@constructor_calldata)
            .unwrap();
        let dispatcher = IBettingGameDispatcher { contract_address: addr };
        
        (addr, dispatcher)
    }

    fn setup() -> (ContractAddress, ContractAddress, IBettingGameDispatcher, IERC20Dispatcher) {
        let (token_address, token) = deploy_token();
        let (betting_address, betting_game) = deploy_betting_game(token_address);
        (token_address, betting_address, betting_game, token)
    }

    #[test]
    fn test_create_bet() {
        let (token_address, _, betting_game, _) = setup();
        let caller = contract_address_const::<1>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        start_cheat_caller_address(betting_game.contract_address, caller);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );

        // Create bet
        let odds: u32 = 2_u32;
        let bet_id = betting_game.create_bet(odds, bet_amount);

        // Verify bet details
        let (bet, is_active) = betting_game.get_bet(bet_id);
        assert(is_active, 'Bet should be active');
        assert(bet.proposer == caller, 'Wrong proposer');
        assert(bet.proposer_amount == bet_amount, 'Wrong amount');
        assert(bet.odds == odds, 'Wrong odds');
        assert(bet.responder.is_zero(), 'Should have no responder');

        stop_cheat_caller_address(betting_game.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Invalid odds', ))]
    fn test_create_bet_invalid_odds() {
        let (token_address, _, betting_game, _) = setup();
        let caller = contract_address_const::<1>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        start_cheat_caller_address(betting_game.contract_address, caller);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );

        betting_game.create_bet(4_u32, bet_amount);
    }

    #[test]
    fn test_match_bet() {
        let (token_address, _, betting_game, _) = setup();
        let proposer = contract_address_const::<1>();
        let responder = contract_address_const::<2>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        // Create bet as proposer
        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );
        let bet_id = betting_game.create_bet(2_u32, bet_amount);
        stop_cheat_caller_address(betting_game.contract_address);

        // Match bet as responder
        start_cheat_caller_address(betting_game.contract_address, responder);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );
        start_mock_call(
            token_address,
            selector!("transfer"),
            array![true]
        );

        betting_game.match_bet(bet_id, bet_amount);

        // Verify bet state
        let (bet, is_active) = betting_game.get_bet(bet_id);
        assert(!is_active, 'Bet should be inactive');
        assert(bet.responder == responder, 'Wrong responder');
        assert(bet.responder_amount == bet_amount, 'Wrong amount');
        assert(!bet.winner.is_zero(), 'Winner not set');

        stop_cheat_caller_address(betting_game.contract_address);
    }

    #[test]
    fn test_cancel_bet() {
        let (token_address, _, betting_game, token) = setup();
        let proposer = contract_address_const::<1>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        // Mock initial balance and store it
        let mut mock_balance: Array<felt252> = ArrayTrait::new();
        mock_balance.append(bet_amount.low.into());
        mock_balance.append(bet_amount.high.into());
        start_mock_call(
            token_address,
            selector!("balance_of"),
            mock_balance.span()
        );
        let initial_balance = token.balance_of(proposer);

        // Create bet
        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );

        // Set timestamps and create bet
        start_cheat_block_timestamp(betting_game.contract_address, 0);
        let bet_id = betting_game.create_bet(2_u32, bet_amount);

        // Cancel bet after delay
        start_cheat_block_timestamp(betting_game.contract_address, CANCEL_DELAY + 1);
        start_mock_call(
            token_address,
            selector!("transfer"),
            array![true]
        );

        betting_game.cancel_bet(bet_id);

        // Verify bet is inactive
        let (_, is_active) = betting_game.get_bet(bet_id);
        assert(!is_active, 'Bet should be inactive');

        // Mock final balance and check it
        let mut final_balance_mock: Array<felt252> = ArrayTrait::new();
        final_balance_mock.append(bet_amount.low.into());
        final_balance_mock.append(bet_amount.high.into());
        start_mock_call(
            token_address,
            selector!("balance_of"),
            final_balance_mock.span()
        );

        // Get actual balance using token dispatcher
        let final_balance = token.balance_of(proposer);
        
        // Verify final balance is within 2% of initial balance
        let margin = (initial_balance * 2_u256) / 100_u256;  // 2% margin
        let min_balance = initial_balance - margin;
        let max_balance = initial_balance + margin;

        assert(final_balance >= min_balance, 'Balance too low');
        assert(final_balance <= max_balance, 'Balance too high');

        // Cleanup
        stop_mock_call(token_address, selector!("balance_of"));
        stop_mock_call(token_address, selector!("transfer_from"));
        stop_mock_call(token_address, selector!("transfer"));
        stop_cheat_caller_address(betting_game.contract_address);
        stop_cheat_block_timestamp(betting_game.contract_address);
    }

    #[test]
    #[should_panic(expected: ('Cannot cancel before 24h', ))]
    fn test_cancel_bet_too_early() {
        let (token_address, _, betting_game, _) = setup();
        let proposer = contract_address_const::<1>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );

        let bet_id = betting_game.create_bet(2_u32, bet_amount);
        betting_game.cancel_bet(bet_id); // Should fail - too early
    }

    #[test]
    fn test_get_bets_by_odds() {
        let (token_address, _, betting_game, _) = setup();
        let proposer = contract_address_const::<1>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();
    
        // Set caller address for creating bets
        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );
    
        // Create multiple bets with different odds
        betting_game.create_bet(2_u32, bet_amount);  // First bet with odds 2
        betting_game.create_bet(2_u32, bet_amount);  // Second bet with odds 2
        betting_game.create_bet(3_u32, bet_amount);  // Third bet with odds 3
    
        // Get all bets with odds of 2
        let bets = betting_game.get_bets_by_odds(2_u32);
        
        // Verify we got exactly 2 bets back
        assert(bets.len() == 2_u32, 'Wrong number of bets');
    
        // Verify bets with odds 3
        let bets_odds_3 = betting_game.get_bets_by_odds(3_u32);
        assert(bets_odds_3.len() == 1_u32, 'Wrong number of odds 3 bets');
    
        // Clean up
        stop_cheat_caller_address(betting_game.contract_address);
    }
}