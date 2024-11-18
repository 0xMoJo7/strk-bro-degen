use starknet::ContractAddress;
use array::Array;

#[derive(Copy, Drop, Hash, starknet::Store, Serde)]
struct Bet {
    proposer: ContractAddress,
    responder: ContractAddress,
    proposer_amount: u256,
    responder_amount: u256,
    odds: u32,
    created_timestamp: u64,
    winner: ContractAddress,
}

#[derive(Copy, Drop, Hash, starknet::Store, Serde)]
struct BetsSummary {
    odds: u32,
    count: u32,
    total_amount: u256,
}

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
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn total_supply(self: @TContractState) -> u256;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
}