mod interfaces;

use interfaces::{
    Bet,
    BetsSummary,
    IBettingGame,
    IERC20,
    IERC20Dispatcher,
    IERC20DispatcherTrait
};

#[starknet::contract]
pub mod BettingGame {
    use super::{
        Bet,
        BetsSummary,
        IBettingGame,
        IERC20,
        IERC20Dispatcher,
        IERC20DispatcherTrait,
    };
    
    use starknet::{
        ContractAddress, 
        get_caller_address,
        get_block_timestamp,
        get_contract_address,
        SyscallResultTrait,
        storage_access::Store,
        storage_access::StorageAddress,
        storage::StorageBaseAddress,
        storage::{
            StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map
        }
    };
    use array::ArrayTrait;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use zeroable::Zeroable;
    use hash::HashStateExTrait;
    use box::BoxTrait;

    const CANCEL_DELAY: u64 = 86400; // 24 hours in seconds
    const FEE_PERCENTAGE: u8 = 1; // 1% fee

    #[storage]
    struct Storage {
        token_address: ContractAddress,
        next_bet_id: u32,
        bet_status: Map::<u32, bool>,
        bet_details: Map::<u32, Bet>,
        fee_collected: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct BetCreated {
        #[key]
        bet_id: u32,
        proposer: ContractAddress,
        amount: u256,
        odds: u32,
        timestamp: u64
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct BetMatched {
        #[key]
        bet_id: u32,
        responder: ContractAddress,
        amount: u256,
        winner: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct BetCancelled {
        #[key]
        bet_id: u32,
        proposer: ContractAddress,
        amount: u256
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    enum Event {
        BetCreated: BetCreated,
        BetMatched: BetMatched,
        BetCancelled: BetCancelled,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token_address: ContractAddress) {
        self.token_address.write(token_address);
        self.next_bet_id.write(1_u32);
        self.fee_collected.write(0_u256);
    }

    #[abi(embed_v0)]
    impl BettingGameImpl of IBettingGame<ContractState> {
        fn create_bet(
            ref self: ContractState,
            odds: u32,
            amount: u256,
        ) -> u32 {
            assert(InternalFunctions::validate_odds(odds), 'Invalid odds');
            assert(amount > 0_u256, 'Amount cannot be zero');

            let caller = get_caller_address();
            let timestamp: u64 = get_block_timestamp().try_into().unwrap();
            let this_contract = get_contract_address();

            let token = IERC20Dispatcher { contract_address: self.token_address.read() };
            token.transfer_from(caller, this_contract, amount);

            let bet_id = self.next_bet_id.read();
            self.next_bet_id.write(bet_id + 1_u32);

            let bet = Bet {
                proposer: caller,
                responder: Zeroable::zero(),
                proposer_amount: amount,
                responder_amount: 0_u256,
                odds,
                created_timestamp: timestamp,
                winner: Zeroable::zero(),
            };

            self.bet_details.write(bet_id, bet);
            self.bet_status.write(bet_id, true);

            self.emit(Event::BetCreated(BetCreated { 
                bet_id, 
                proposer: caller, 
                amount, 
                odds, 
                timestamp 
            }));

            bet_id
        }

        fn match_bet(
            ref self: ContractState,
            bet_id: u32,
            amount: u256,
        ) {
            let mut bet = self.bet_details.read(bet_id);
            let is_active = self.bet_status.read(bet_id);
            
            assert(is_active, 'Bet is not active');
            assert(bet.responder.is_zero(), 'Bet already matched');

            let caller = get_caller_address();
            assert(caller != bet.proposer, 'Cannot match own bet');
            let this_contract = get_contract_address();

            let token = IERC20Dispatcher { contract_address: self.token_address.read() };
            token.transfer_from(caller, this_contract, amount);

            let timestamp: u64 = get_block_timestamp().try_into().unwrap();
            let random = timestamp % bet.odds.into();
            let winner = if random == 0_u64 { bet.proposer } else { caller };

            let total_pot = bet.proposer_amount + amount;
            let winner_amount = if random == 0_u64 {
                total_pot
            } else {
                let winnings = bet.proposer_amount * (bet.odds - 1_u32).into() / bet.odds.into();
                amount + winnings
            };

            let fee = InternalFunctions::calculate_fee(winner_amount);
            let final_amount = winner_amount - fee;

            token.transfer(winner, final_amount);
            
            bet.responder = caller;
            bet.responder_amount = amount;
            bet.winner = winner;
            self.bet_details.write(bet_id, bet);
            self.bet_status.write(bet_id, false);

            let current_fees = self.fee_collected.read();
            self.fee_collected.write(current_fees + fee);

            self.emit(Event::BetMatched(BetMatched { 
                bet_id, 
                responder: caller, 
                amount, 
                winner 
            }));
        }

        fn cancel_bet(ref self: ContractState, bet_id: u32) {
            let bet = self.bet_details.read(bet_id);
            let is_active = self.bet_status.read(bet_id);
            
            assert(is_active, 'Bet is not active');
            let caller = get_caller_address();
            assert(caller == bet.proposer, 'Only proposer can cancel');

            let timestamp: u64 = get_block_timestamp().try_into().unwrap();
            assert(
                timestamp >= bet.created_timestamp + CANCEL_DELAY,
                'Cannot cancel before 24h'
            );

            let token = IERC20Dispatcher { contract_address: self.token_address.read() };
            token.transfer(bet.proposer, bet.proposer_amount);

            self.bet_status.write(bet_id, false);

            self.emit(Event::BetCancelled(BetCancelled { 
                bet_id, 
                proposer: caller, 
                amount: bet.proposer_amount 
            }));
        }

        fn get_bets_by_odds(self: @ContractState, odds: u32) -> Array<Bet> {
            assert(InternalFunctions::validate_odds(odds), 'Invalid odds');
            
            let mut active_bets = ArrayTrait::new();
            let mut current_id = 1_u32;
            let max_id = self.next_bet_id.read();
            
            loop {
                if current_id >= max_id {
                    break;
                }
                
                if self.bet_status.read(current_id) {
                    let bet = self.bet_details.read(current_id);
                    if bet.odds == odds && bet.responder.is_zero() {
                        active_bets.append(bet);
                    }
                }
                current_id += 1_u32;
            };
            
            active_bets
        }

        fn get_active_bets_summary(self: @ContractState) -> Array<BetsSummary> {
            let mut summaries = ArrayTrait::new();
            let odds_array = array![1_u32, 2_u32, 3_u32, 5_u32, 10_u32, 100_u32, 1000_u32];
            
            let mut i = 0_u32;
            loop {
                if i >= odds_array.len() {
                    break;
                }
                
                let odds = *odds_array.at(i.try_into().unwrap());
                let bets = self.get_bets_by_odds(odds);
                
                let mut total_amount = 0_u256;
                let mut count = 0_u32;
                
                let mut j = 0_u32;
                loop {
                    if j >= bets.len() {
                        break;
                    }
                    
                    let bet = *bets.at(j.try_into().unwrap());
                    total_amount = total_amount + bet.proposer_amount;
                    count += 1_u32;
                    j += 1_u32;
                };
                
                if count > 0_u32 {
                    summaries.append(BetsSummary { odds, count, total_amount });
                }
                
                i += 1_u32;
            };
            
            summaries
        }

        fn get_user_active_bets(
            self: @ContractState, 
            user: ContractAddress
        ) -> Array<(u32, Bet)> {
            let mut user_bets = ArrayTrait::new();
            let mut current_id = 1_u32;
            let max_id = self.next_bet_id.read();
            
            loop {
                if current_id >= max_id {
                    break;
                }
                
                if self.bet_status.read(current_id) {
                    let bet = self.bet_details.read(current_id);
                    if bet.proposer == user && bet.responder.is_zero() {
                        user_bets.append((current_id, bet));
                    }
                }
                current_id += 1_u32;
            };
            
            user_bets
        }

        fn get_user_bet_history(
            self: @ContractState,
            user: ContractAddress
        ) -> Array<(u32, Bet)> {
            let mut user_bets = ArrayTrait::new();
            let mut current_id = 1_u32;
            let max_id = self.next_bet_id.read();
            
            loop {
                if current_id >= max_id {
                    break;
                }
                
                if !self.bet_status.read(current_id) {
                    let bet = self.bet_details.read(current_id);
                    if bet.proposer == user || bet.responder == user {
                        user_bets.append((current_id, bet));
                    }
                }
                current_id += 1_u32;
            };
            
            user_bets
        }

        fn is_bet_cancellable(self: @ContractState, bet_id: u32) -> bool {
            let bet = self.bet_details.read(bet_id);
            let is_active = self.bet_status.read(bet_id);
            let timestamp: u64 = get_block_timestamp().try_into().unwrap();
            
            if !is_active || !bet.responder.is_zero() {
                return false;
            }
            
            timestamp >= bet.created_timestamp + CANCEL_DELAY
        }

        fn get_bet(self: @ContractState, bet_id: u32) -> (Bet, bool) {
            let bet = self.bet_details.read(bet_id);
            let is_active = self.bet_status.read(bet_id);
            (bet, is_active)
        }

        fn get_total_fees(self: @ContractState) -> u256 {
            self.fee_collected.read()
        }

        fn get_token_address(self: @ContractState) -> ContractAddress {
            self.token_address.read()
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn validate_odds(odds: u32) -> bool {
            let valid_odds = array![1_u32, 2_u32, 3_u32, 5_u32, 10_u32, 100_u32, 1000_u32];
            let mut i = 0_u32;
            
            loop {
                if i >= valid_odds.len() {
                    break false;
                }
                if *valid_odds.at(i.try_into().unwrap()) == odds {
                    break true;
                }
                i += 1_u32;
            }
        }

        fn calculate_fee(amount: u256) -> u256 {
            (amount * FEE_PERCENTAGE.into()) / 100_u256
        }
    }
}