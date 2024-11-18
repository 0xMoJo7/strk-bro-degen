#[cfg(test)]
mod tests {
    use core::traits::TryInto;
    use starknet::{
        ContractAddress,
        testing::set_block_timestamp,
        contract_address_const,
        get_caller_address
    };
    use snforge_std::{
        declare,
        DeclareResultTrait,
        ContractClassTrait,
        ContractClass,
        start_cheat_caller_address,
        stop_cheat_caller_address,
        start_mock_call,
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

    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};

    const INITIAL_SUPPLY: u256 = 1000000000000000000000; // 1000 tokens with 18 decimals
    const CANCEL_DELAY: u64 = 86400_u64; // 24 hours in seconds
    const BET_AMOUNT: felt252 = 100000000000000000000; // 100 tokens

    #[starknet::contract]
    mod ERC20 {
        use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
        use starknet::ContractAddress;

        component!(path: ERC20Component, storage: erc20, event: ERC20Event);

        #[abi(embed_v0)]
        impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
        #[abi(embed_v0)]
        impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
        impl InternalImpl = ERC20Component::InternalImpl<ContractState>;

        #[storage]
        struct Storage {
            #[substorage(v0)]
            erc20: ERC20Component::Storage
        }

        #[event]
        #[derive(Drop, starknet::Event)]
        enum Event {
            #[flat]
            ERC20Event: ERC20Component::Event
        }

        #[constructor]
        fn constructor(
            ref self: ContractState,
            initial_supply: u256,
            recipient: ContractAddress
        ) {
            let name = "MyToken";
            let symbol = "MTK";
    
            self.erc20.initializer(name, symbol);
            self.erc20.mint(recipient, initial_supply);
        }
    }

    fn deploy_token() -> (ContractAddress, IERC20Dispatcher) {
        let contract = declare("ERC20").unwrap().contract_class();
        let recipient = starknet::get_caller_address();
        let constructor_calldata = array![INITIAL_SUPPLY, recipient.into()];
        
        let (addr, _) = contract
            .deploy(@constructor_calldata)
            .unwrap();
        let dispatcher = IERC20Dispatcher { contract_address: addr };
        
        (addr, dispatcher)
    }

    fn deploy_betting_game(token: ContractAddress) -> (ContractAddress, IBettingGameDispatcher) {
        let contract = declare("brother_betting::BettingGame").unwrap().contract_class();
        let constructor_calldata = array![token.into()];
        
        let (addr, _data) = contract
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

        // Update prank calls to match documentation
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

        set_block_timestamp(1000);
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
        let (token_address, _, betting_game, _) = setup();
        let proposer = contract_address_const::<1>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        // Create bet
        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );
        let bet_id = betting_game.create_bet(2_u32, bet_amount);

        // Set future timestamp and mock refund
        set_block_timestamp(CANCEL_DELAY + 1);
        start_mock_call(
            token_address,
            selector!("transfer"),
            array![true]
        );

        // Cancel bet
        betting_game.cancel_bet(bet_id);

        // Verify cancellation
        let (_, is_active) = betting_game.get_bet(bet_id);
        assert(!is_active, 'Bet should be inactive');

        stop_cheat_caller_address(betting_game.contract_address);
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

        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );

        // Create multiple bets
        betting_game.create_bet(2_u32, bet_amount);
        betting_game.create_bet(2_u32, bet_amount);
        betting_game.create_bet(3_u32, bet_amount);

        let bets = betting_game.get_bets_by_odds(2_u32);
        assert(bets.len() == 2_u32, 'Wrong number of bets');

        stop_cheat_caller_address(betting_game.contract_address);
    }

    #[test]
    fn test_fee_collection() {
        let (token_address, _, betting_game, _) = setup();
        let proposer = contract_address_const::<1>();
        let responder = contract_address_const::<2>();
        let bet_amount: u256 = BET_AMOUNT.try_into().unwrap();

        // Create bet
        start_cheat_caller_address(betting_game.contract_address, proposer);
        start_mock_call(
            token_address,
            selector!("transfer_from"),
            array![true]
        );
        let bet_id = betting_game.create_bet(2_u32, bet_amount);
        stop_cheat_caller_address(betting_game.contract_address);

        // Match bet
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

        // Verify fees
        let total_fees = betting_game.get_total_fees();
        let expected_fees = (bet_amount * 2_u256 * 1_u256) / 100_u256;
        assert(total_fees == expected_fees, 'Wrong fee amount');

        stop_cheat_caller_address(betting_game.contract_address);
    }
}