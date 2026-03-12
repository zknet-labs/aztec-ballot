use aztec::macros::aztec;

#[aztec]
pub contract PrivateVoting {
    use aztec::{
        keys::getters::get_public_keys,
        macros::{functions::{external, initializer, only_self}, storage::storage},
    };
    use aztec::protocol::{
        address::AztecAddress,
        hash::poseidon2_hash,
        traits::{Hash, ToField},
    };
    use aztec::state_vars::{Map, PublicImmutable, PublicMutable};
    use aztec::context::UtilityContext;

    use operations::Operations;

    #[storage]
    struct Storage<Context> {
        admin: PublicMutable<AztecAddress, Context>,
        tally: Map<Field, PublicMutable<Field, Context>, Context>,
        vote_ended: PublicMutable<bool, Context>,
        vote_start_timestamp: PublicImmutable<u64, Context>,
        vote_deadline_timestamp: PublicImmutable<u64, Context>,
        operations_contract: PublicImmutable<AztecAddress, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(
        admin: AztecAddress,
        operations_addr: AztecAddress,
        vote_start_delay_seconds: u64,
        vote_duration_seconds: u64,
    ) {
        self.storage.admin.write(admin);
        self.storage.vote_ended.write(false);
        let now: u64 = self.context.timestamp();
        let start: u64 = now + vote_start_delay_seconds;
        self.storage.vote_start_timestamp.initialize(start);
        self.storage.vote_deadline_timestamp.initialize(start + vote_duration_seconds);
        self.storage.operations_contract.initialize(operations_addr);
    }

    #[external("private")]
    fn cast_vote() {
        let agent: AztecAddress = self.context.maybe_msg_sender().unwrap();
        let operations_addr: AztecAddress = self.storage.operations_contract.read();

        let candidate: Field = self.call(
            Operations::at(operations_addr).consume_vote_instruction(agent)
        );

        let npk_hash = get_public_keys(agent).npk_m.hash();
        let secret = self.context.request_nhk_app(npk_hash);
        let nullifier = poseidon2_hash([agent.to_field(), secret]);
        self.context.push_nullifier(nullifier);

        self.enqueue_self.add_to_tally_public(candidate);

        self.enqueue(Operations::at(operations_addr)._mark_voted_public(agent));
    }

    #[only_self]
    #[external("public")]
    fn add_to_tally_public(candidate: Field) {
        assert(self.storage.vote_ended.read() == false, "Vote has ended");

        let current: u64 = self.context.timestamp();
        let start: u64 = self.storage.vote_start_timestamp.read();
        let deadline: u64 = self.storage.vote_deadline_timestamp.read();

        assert(current >= start, "Voting has not started yet");
        assert(current <= deadline, "Voting period has expired");

        let new_tally = self.storage.tally.at(candidate).read() + 1;
        self.storage.tally.at(candidate).write(new_tally);
    }

    #[external("public")]
    fn end_vote() {
        assert(
            self.storage.admin.read().eq(self.msg_sender()),
            "Only admin can end votes",
        );
        self.storage.vote_ended.write(true);
    }

    #[external("utility")]
    unconstrained fn get_vote(candidate: Field) -> pub Field {
        let ended: bool = self.storage.vote_ended.read();
        if !ended {
            let deadline: u64 = self.storage.vote_deadline_timestamp.read();
            let now: u64 = UtilityContext::new().timestamp();
            assert(now > deadline, "Voting window has not closed yet");
        }
        self.storage.tally.at(candidate).read()
    }

    #[external("utility")]
    unconstrained fn is_vote_finished() -> pub bool {
        if self.storage.vote_ended.read() {
            true
        } else {
            let deadline: u64 = self.storage.vote_deadline_timestamp.read();
            let now: u64 = UtilityContext::new().timestamp();
            now > deadline
        }
    }

    #[external("utility")]
    unconstrained fn get_start_timestamp() -> pub u64 {
        self.storage.vote_start_timestamp.read()
    }

    #[external("utility")]
    unconstrained fn get_deadline_timestamp() -> pub u64 {
        self.storage.vote_deadline_timestamp.read()
    }
}
