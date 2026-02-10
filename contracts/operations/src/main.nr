use aztec::macros::aztec;

#[aztec]
pub contract Operations {
    use aztec::macros::{functions::external, functions::initializer, storage::storage};

    use aztec::state_vars::{Map, Owned, PrivateSet, PublicMutable, PublicImmutable};

    use aztec::protocol_types::address::AztecAddress;

    use aztec::note::note_getter_options::NoteGetterOptions;

    use field_note::field_note::FieldNote;

    use aztec::messages::message_delivery::MessageDelivery;

    use registry::AgentRegistry;

    // -------------------------
    // Storage
    // -------------------------
    #[storage]
    struct Storage<Context> {
        // Public: agent -> has_voted (only public state , reveals nothing about operator)
        has_voted: Map<AztecAddress, PublicMutable<bool, Context>, Context>,

        // Private (agent-owned): authorization notes
        auth_notes: Owned<PrivateSet<FieldNote, Context>, Context>,

        // Private (agent-owned): revocation notes
        revocations: Owned<PrivateSet<FieldNote, Context>, Context>,

        // Public: address of the registry contract we trust
        registry: PublicImmutable<AztecAddress, Context>,

        // Private (agent-owned): vote instruction notes
        vote_instructions: Owned<PrivateSet<FieldNote, Context>, Context>,
    }

    // -------------------------
    // Public initializer
    // -------------------------
    #[external("public")]
    #[initializer]
    fn constructor(registry_addr: AztecAddress) {
        self.storage.registry.initialize(registry_addr);
    }

    // -------------------------
    // Operator: authorize / revoke agent (fully private)
    // -------------------------
    #[external("private")]
    fn configure_agent_registration(agent: AztecAddress, is_registered: bool) {
        let registry_addr = self.storage.registry.read();
        let operator = self.context.msg_sender().unwrap();

        let _ = self.call(
            AgentRegistry::at(registry_addr).prove_association_for(operator, agent)
        );

        let capability = FieldNote { value: 1 };

        if is_registered {
            self.storage.auth_notes
                .at(agent)
                .insert(capability)
                .deliver(MessageDelivery.UNCONSTRAINED_ONCHAIN);
        } else {
            self.storage.revocations
                .at(agent)
                .insert(capability)
                .deliver(MessageDelivery.UNCONSTRAINED_ONCHAIN);
        }
    }

    // -------------------------
    // Operator: issue vote instruction to agent (fully private)
    // -------------------------
    /// Proves operator-agent association via Registry (implying authorization),
    /// then mints a vote instruction note owned by the agent.
    #[external("private")]
    fn issue_vote_instruction(agent: AztecAddress, candidate: Field) {
        let registry_addr: AztecAddress = self.storage.registry.read();
        let operator: AztecAddress = self.context.msg_sender().unwrap();

        let _: () = self.call(
            AgentRegistry::at(registry_addr).prove_association_for(operator, agent)
        );

        let instruction = FieldNote { value: candidate };
        self.storage.vote_instructions
            .at(agent)
            .insert(instruction)
            .deliver(MessageDelivery.UNCONSTRAINED_ONCHAIN);
    }

    // -------------------------
    // Agent: read vote instruction (lightweight)
    // -------------------------
    /// Reads the vote instruction note and returns the candidate.
    /// Authorization is enforced by the fact that only an authorized
    /// operator can issue instructions via issue_vote_instruction.
    /// Double-voting is prevented by the nullifier in PrivateVoting.
    #[external("private")]
    fn consume_vote_instruction(agent: AztecAddress) -> Field {
        let options: NoteGetterOptions<FieldNote, 1, Field, Field> = NoteGetterOptions::new();
        let instructions = self.storage.vote_instructions
            .at(agent)
            .get_notes::<Field, Field, 1>(options);

        assert(instructions.len() > 0, "No vote instruction from operator");

        let instruction = instructions.get(0);
        instruction.note.value
    }

    // -------------------------
    // Public: mark agent as having voted (called by PrivateVoting)
    // -------------------------
    #[external("public")]
    fn _mark_voted_public(agent: AztecAddress) {
        self.storage.has_voted.at(agent).write(true);
    }

    // -------------------------
    // Public read
    // -------------------------
    #[external("public")]
    fn get_has_voted(agent: AztecAddress) -> bool {
        self.storage.has_voted.at(agent).read()
    }
}

mod test {
    use crate::Operations;

    use aztec::test::helpers::test_environment::TestEnvironment;
    use aztec::protocol_types::address::AztecAddress;

    use registry::AgentRegistry;

    unconstrained fn setup()
    -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress, AztecAddress)
    {
        let mut env = TestEnvironment::new();

        let operator = env.create_light_account();
        let agent = env.create_light_account();

        let registry_addr = env
        .deploy("AgentRegistry")
        .without_initializer();

        env.call_private(
            operator,
            AgentRegistry::at(registry_addr).register_agent(agent),
        );

        let system_addr = env
            .deploy("Operations")
            .with_public_initializer(operator, Operations::interface().constructor(registry_addr));

        (env, system_addr, registry_addr, operator, agent)
    }

    #[test]
    unconstrained fn test_authorized_agent_can_consume_instruction() {
        let (mut env, system_addr, _registry_addr, operator, agent) = setup();

        // Authorize
        env.call_private(
            operator,
            Operations::at(system_addr).configure_agent_registration(agent, true),
        );

        // Issue instruction for candidate 3
        env.call_private(
            operator,
            Operations::at(system_addr).issue_vote_instruction(agent, 3),
        );

        // Agent consumes, should succeed
        let candidate: Field = env.call_private(
            agent,
            Operations::at(system_addr).consume_vote_instruction(agent),
        );

        assert(candidate == 3, "expected candidate 3");
    }

    #[test(should_fail_with = "No vote instruction from operator")]
    unconstrained fn test_consume_fails_without_instruction() {
        let (mut env, system_addr, _registry_addr, operator, agent) = setup();

        // Authorize but do NOT issue instruction
        env.call_private(
            operator,
            Operations::at(system_addr).configure_agent_registration(agent, true),
        );

        // Agent tries to consume, no instruction exists
        let _: Field = env.call_private(
            agent,
            Operations::at(system_addr).consume_vote_instruction(agent),
        );
    }

    #[test(should_fail_with = "Not associated")]
    unconstrained fn test_issue_fails_without_registration() {
        let (mut env, system_addr, _registry_addr, _operator, _agent) = setup();

        // Create a rogue operator who never registered the agent
        let rogue = env.create_light_account();

        // Rogue tries to issue instruction, fails at registry proof
        env.call_private(
            rogue,
            Operations::at(system_addr).issue_vote_instruction(_agent, 3),
        );
    }

    #[test(should_fail_with = "Association revoked")]
    unconstrained fn test_issue_fails_after_unregister() {
        let (mut env, system_addr, registry_addr, operator, agent) = setup();

        // Unregister in the registry
        env.call_private(
            operator,
            registry::AgentRegistry::at(registry_addr).unregister_agent(agent),
        );

        // Operator tries to issue instruction, registry proof fails
        env.call_private(
            operator,
            Operations::at(system_addr).issue_vote_instruction(agent, 3),
        );
    }
}