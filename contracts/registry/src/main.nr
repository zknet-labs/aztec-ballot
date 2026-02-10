use aztec::macros::aztec;

#[aztec]
pub contract AgentRegistry {
    use aztec::macros::{functions::external, storage::storage};
    use aztec::state_vars::{Owned, PrivateSet};

    // Note type: a single Field
    use field_note::field_note::FieldNote;

    // Note retrieval
    use aztec::note::note_getter_options::NoteGetterOptions;

    // Types
    use aztec::protocol_types::address::AztecAddress;
    use dep::aztec::protocol_types::traits::ToField;

    // For returning lists
    use std::collections::bounded_vec::BoundedVec;
    use aztec::messages::message_delivery::MessageDelivery;

    #[storage]
    struct Storage<Context> {
        // Operator -> set of FieldNote(value = agent.to_field())
        associations: Owned<PrivateSet<FieldNote, Context>, Context>,

        // Operator -> set of FieldNote(value = agent.to_field()) meaning "revoked"
        revocations: Owned<PrivateSet<FieldNote, Context>, Context>,
    }

    // -------------------------
    // External (private) API
    // -------------------------

    /// register_agent(agent: AztecAddress)
    /// Private. Callable by Operator. Stores association note owned by Operator.
    #[external("private")]
    fn register_agent(agent: AztecAddress) {
        let operator = self.context.msg_sender().unwrap();

        let note = FieldNote { value: agent.to_field() };

        self.storage.associations
            .at(operator)
            .insert(note)
            .deliver(MessageDelivery.CONSTRAINED_ONCHAIN);
    }

    /// unregister_agent(agent: AztecAddress)
    /// Private. Callable by Operator. Adds a revocation marker note.
    #[external("private")]
    fn unregister_agent(agent: AztecAddress) {
        let operator = self.context.msg_sender().unwrap();

        let revoke_note = FieldNote { value: agent.to_field() };

        self.storage.revocations
            .at(operator)
            .insert(revoke_note)
            .deliver(MessageDelivery.CONSTRAINED_ONCHAIN);
    }

    /// Private. Succeeds iff register_count > revoke_count for this agent.
    #[external("private")]
    fn prove_association_for(operator: AztecAddress, agent: AztecAddress) {
        let agent_field = agent.to_field();

        // Read all association notes for operator
        let assoc_options = NoteGetterOptions::<FieldNote, 1, Field, Field>::new();
        let assoc_notes = self.storage.associations
            .at(operator)
            .get_notes::<Field, Field, 1>(assoc_options);

        let assoc_len = assoc_notes.len();
        let mut register_count: u32 = 0;

        for i in 0..16 {
            if i < assoc_len {
                let r = assoc_notes.get(i);
                if r.note.value == agent_field {
                    register_count += 1;
                }
            }
        }

        assert(register_count > 0, "Not associated");

        // --- Revocation notes for operator ---
        let rev_options = NoteGetterOptions::<FieldNote, 1, Field, Field>::new();
        let rev_notes = self.storage.revocations
            .at(operator)
            .get_notes::<Field, Field, 1>(rev_options);

        let rev_len = rev_notes.len();
        let mut revoke_count: u32 = 0;

        for i in 0..16 {
            if i < rev_len {
                let r = rev_notes.get(i);
                if r.note.value == agent_field {
                    revoke_count += 1;
                }
            }
        }

        // Agent is active iff they've been registered more times than revoked
        assert(register_count > revoke_count, "Association revoked");
    }

    #[external("private")]
    fn list_registered_agents_for_operator() -> BoundedVec<Field, 16> {
        let operator = self.context.msg_sender().unwrap();

        let options = NoteGetterOptions::<FieldNote, 1, Field, Field>::new();
        let notes = self.storage.associations
            .at(operator)
            .get_notes::<Field, Field, 1>(options);

        let mut out: BoundedVec<Field, 16> = BoundedVec::new();
        let len = notes.len();

        for i in 0..16 {
            if i < len {
                let retrieved = notes.get(i);
                let _ = out.push(retrieved.note.value);
            }
        }

        out
    }


// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------
mod test {
    use crate::AgentRegistry;

    use aztec::{
        protocol_types::address::AztecAddress,
        test::helpers::test_environment::TestEnvironment,
    };

 unconstrained fn setup()
    -> (TestEnvironment, AztecAddress, AztecAddress, AztecAddress)
    {
        let mut env = TestEnvironment::new();

        let operator = env.create_light_account();
        let agent = env.create_light_account();

        let registry_addr = env
            .deploy("AgentRegistry")
            .without_initializer();

        (env, registry_addr, operator, agent)
    }

    #[test]
    unconstrained fn test_register_and_prove_ok() {
        let (mut env, registry, operator, agent) = setup();

        env.call_private(
            operator,
            AgentRegistry::at(registry).register_agent(agent),
        );

        env.call_private(
            operator,
            AgentRegistry::at(registry).prove_association_for(operator, agent),
        );
    }

    #[test(should_fail_with = "Not associated")]
    unconstrained fn test_prove_fails_when_not_registered() {
        let (mut env, registry, operator, agent) = setup();

        env.call_private(
            operator,
            AgentRegistry::at(registry).prove_association_for(operator, agent),
        );
    }

    #[test(should_fail_with = "Association revoked")]
    unconstrained fn test_prove_fails_after_revoke() {
        let (mut env, registry, operator, agent) = setup();

        env.call_private(
            operator,
            AgentRegistry::at(registry).register_agent(agent),
        );

        env.call_private(
            operator,
            AgentRegistry::at(registry).unregister_agent(agent),
        );

        env.call_private(
            operator,
            AgentRegistry::at(registry).prove_association_for(operator, agent),
        );
    }

    #[test]
    unconstrained fn test_re_register_after_revoke() {
        let (mut env, registry, operator, agent) = setup();

        // Register
        env.call_private(
            operator,
            AgentRegistry::at(registry).register_agent(agent),
        );

        // Unregister
        env.call_private(
            operator,
            AgentRegistry::at(registry).unregister_agent(agent),
        );

        // Re-register
        env.call_private(
            operator,
            AgentRegistry::at(registry).register_agent(agent),
        );

        // Should succeed: 2 registrations > 1 revocation
        env.call_private(
            operator,
            AgentRegistry::at(registry).prove_association_for(operator, agent),
        );
    }
}

}