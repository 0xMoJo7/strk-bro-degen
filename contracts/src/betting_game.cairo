use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::get_block_timestamp;
use starknet::get_contract_address;
use array::ArrayTrait;
use array::SpanTrait;
use option::OptionTrait;
use zeroable::Zeroable;
use traits::Into;
use starknet::Store;
use starknet::storage::StorageAccess;

#[starknet::interface]
trait IBettingGame<TContractState> {
    fn create_bet(ref self: TContractState, odds: u32, amount: u256) -> u32;
    fn match_bet(ref self: TContractState, bet_id: u32, amount: u256);
    fn cancel_bet(ref self: TContractState, bet_id: u32);
    fn get_bets_by_odds(self: @TContractState, odds: u32) -> Array<Bet>;
    fn get_active_bets_summary(self: @TContractState) -> Array<BetsSummary>;
    fn get_user_active_bets(self: @TContractState, user: ContractAddress) -> Array<(u32, Bet)>;
    fn get_user_bet_history(self: @TContractState, user: ContractAddress) -> Array<(u32, Bet)>;
    fn is_bet_cancellable(self: @TContractState, bet_id: u32) -> bool;
    fn get_bet(self: @TContractState, bet_id: u32) -> (Bet, bool);
    fn get_total_fees(self: @TContractState) -> u256;
    fn get_token_address(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256
    ) -> bool;
}

#[derive(Drop, Copy, Serde, starknet::Store)]
struct Bet {
    proposer: ContractAddress,
    responder: ContractAddress,
    proposer_amount: u256,
    responder_amount: u256,
    odds: u32,
    created_timestamp: u64,
    winner: ContractAddress,
}

#[derive(Drop, Copy, Serde)]
struct BetsSummary {
    odds: u32,
    count: u32,
    total_amount: u256,
}

#[starknet::contract]
mod BettingGame {
    use super::{
        Bet, BetsSummary, ContractAddress, IERC20DispatcherTrait, IERC20Dispatcher, IBettingGame,
        Store, StorageAccess
    };
    use starknet::{get_caller_address, get_block_timestamp, get_contract_address};
    use array::ArrayTrait;
    use array::SpanTrait;
    use option::OptionTrait;
    use traits::Into;
    use traits::TryInto;
    use zeroable::Zeroable;

    const FEE_PERCENTAGE: u8 = 1; // 1% fee
    const CANCEL_DELAY: u64 = 86400; // 24 hours in seconds

    #[storage]
    struct Storage {
        token_address: ContractAddress,
        next_bet_id: u32,
        bet_status: Map::<u32, bool>,
        bet_details: Map::<u32, Bet>,
        fee_collected: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BetCreated: BetCreated,
        BetMatched: BetMatched,
        BetCancelled: BetCancelled,
    }

    #[derive(Drop, starknet::Event)]
    struct BetCreated {
        bet_id: u32,
        proposer: ContractAddress,
        amount: u256,
        odds: u32,
        timestamp: u64
    }

    #[derive(Drop, starknet::Event)]
    struct BetMatched {
        bet_id: u32,
        responder: ContractAddress,
        amount: u256,
        winner: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct BetCancelled {
        bet_id: u32,
        proposer: ContractAddress,
        amount: u256
    }

    #[constructor]
    fn constructor(ref self: ContractState, token_address: ContractAddress) {
        self.token_address.write(token_address);
        self.next_bet_id.write(1_u32);
        self.fee_collected.write(0_u256);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _validate_odds(odds: u32) -> bool {
            if odds == 1_u32 {
                return true;
            }
            if odds == 2_u32 {
                return true;
            }
            if odds == 3_u32 {
                return true;
            }
            if odds == 5_u32 {
                return true;
            }
            if odds == 10_u32 {
                return true;
            }
            if odds == 100_u32 {
                return true;
            }
            if odds == 1000_u32 {
                return true;
            }
            false
        }

        fn _determine_winner(
            timestamp: u64, 
            odds: u32, 
            proposer: ContractAddress, 
            responder: ContractAddress
        ) -> ContractAddress {
            let random = timestamp % (odds.into());
            if random == 0_u64 {
                proposer
            } else {
                responder
            }
        }

        fn _calculate_fee(amount: u256) -> u256 {
            (amount * FEE_PERCENTAGE.into()) / 100_u256
        }
    }

    #[abi(embed_v0)]
    impl BettingGameImpl of super::IBettingGame<ContractState> {
        fn create_bet(
            ref self: ContractState,
            odds: u32,
            amount: u256,
        ) -> u32 {
            assert(InternalFunctions::_validate_odds(odds), 'Invalid odds');
            assert(amount > 0_u256, 'Amount cannot be zero');

            let caller = get_caller_address();
            let timestamp: u64 = get_block_timestamp().try_into().unwrap();
            let this_contract = get_contract_address();

            let token = IERC20Dispatcher { contract_address: self.token_address.read() };
            token.transfer_from(caller, this_contract, amount);

            let bet_id = self.next_bet_id.read();
            self.next_bet_id.write(bet_id + 1_u32);

            let new_bet = Bet {
                proposer: caller,
                responder: Zeroable::zero(),
                proposer_amount: amount,
                responder_amount: 0_u256,
                odds,
                created_timestamp: timestamp,
                winner: Zeroable::zero(),
            };

            self.bet_details.write(bet_id, new_bet);
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
            let bet = self.bet_details.StorageMapReadAccess::read(bet_id);
            let is_active = self.bet_status.StorageMapReadAccess::read(bet_id);
            
            assert(is_active, 'Bet is not active');
            assert(bet.responder.is_zero(), 'Bet already matched');

            let caller = get_caller_address();
            assert(caller != bet.proposer, 'Cannot match own bet');
            let this_contract = get_contract_address();

            let token = IERC20Dispatcher { contract_address: self.token_address.read() };
            token.transfer_from(caller, this_contract, amount);

            let timestamp: u64 = get_block_timestamp().try_into().unwrap();
            let winner = InternalFunctions::_determine_winner(timestamp, bet.odds, bet.proposer, caller);

            let total_pot = amount + bet.proposer_amount;
            let fee = InternalFunctions::_calculate_fee(total_pot);
            let winning_amount = total_pot - fee;

            token.transfer(winner, winning_amount);

            let current_fees = self.fee_collected.read();
            self.fee_collected.write(current_fees + fee);

            self.bet_status.write(bet_id, false);

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
            assert(InternalFunctions::_validate_odds(odds), 'Invalid odds');
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
            let odds = array![1_u32, 2_u32, 3_u32, 5_u32, 10_u32, 100_u32, 1000_u32];
            
            let mut i = 0_u32;
            loop {
                if i >= odds.len() {
                    break;
                }
                
                let current_odds = *odds.at(i.try_into().unwrap());
                let active_bets = self.get_bets_by_odds(current_odds);
                let mut total_amount = 0_u256;
                let mut count = 0_u32;
                
                let mut j = 0_u32;
                loop {
                    if j >= active_bets.len() {
                        break;
                    }
                    
                    let bet = *active_bets.at(j.try_into().unwrap());
                    total_amount = total_amount + bet.proposer_amount;
                    count += 1_u32;
                    j += 1_u32;
                };
                
                summaries.append(BetsSummary {
                    odds: current_odds,
                    count,
                    total_amount
                });
                i += 1_u32;
            };
            
            summaries
        }

        fn get_user_active_bets(self: @ContractState, user: ContractAddress) -> Array<(u32, Bet)> {
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

        fn get_user_bet_history(self: @ContractState, user: ContractAddress) -> Array<(u32, Bet)> {
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
}