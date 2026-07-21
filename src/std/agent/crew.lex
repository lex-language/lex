// std/agent/crew.lex — Multi-Agent Crews
//
// Uma Crew é uma equipe de agents que trabalham juntos.
// Suporta diferentes padrões de workflow:
//   - Sequential: Agents executam em sequência
//   - Parallel: Agents executam em paralelo
//   - Hierarchical: Um agent coordena os outros
//
// Uso:
//   import { Crew, CrewConfig } from "std/agent/crew"
//
//   const crew: Crew = new Crew("engineering-team")
//   crew.addAgent(architect)
//   crew.addAgent(developer)
//   crew.setWorkflow(WorkflowType.Sequential)
//   const result: CrewResult = crew.run(task)

import { Agent, AgentResult, AgentConfig } from "./agent"
import { Message, userMsg, assistantMsg } from "../ai/types"

// ══════════════════════════════════════════════════════════════════════════════
// TIPOS DE WORKFLOW
// ══════════════════════════════════════════════════════════════════════════════

/// Tipo de workflow da crew
enum WorkflowType {
    Sequential,    // Agents executam um após o outro
    Parallel,      // Agents executam simultaneamente
    Hierarchical,  // Um agent manager coordena os outros
    RoundRobin,    // Agents se alternam
    Consensus      // Agents votam em decisões
}

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURAÇÃO DA CREW
// ══════════════════════════════════════════════════════════════════════════════

/// Configuração de uma crew
class CrewConfig {
    name: string
    description: string
    workflowType: WorkflowType
    maxRounds: i64            // Para RoundRobin/Consensus
    managerAgent: string      // Nome do agent manager (para Hierarchical)
    quorum: i64               // Votos necessários (para Consensus)
    verbose: bool             // Logar ações

    constructor() {
        this.name = "crew"
        this.description = ""
        this.workflowType = WorkflowType.Sequential
        this.maxRounds = 10
        this.managerAgent = ""
        this.quorum = 0
        this.verbose = false
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// RESULTADO DA CREW
// ══════════════════════════════════════════════════════════════════════════════

/// Resultado de um agent na crew
class AgentOutput {
    agentName: string
    result: AgentResult
    order: i64

    constructor(name: string, result: AgentResult, order: i64) {
        this.agentName = name
        this.result = result
        this.order = order
    }
}

/// Resultado da execução da crew
class CrewResult {
    success: bool
    finalOutput: string
    agentOutputs: AgentOutput[]
    error: string
    totalTurns: i64

    constructor() {
        this.success = false
        this.finalOutput = ""
        this.agentOutputs = []
        this.error = ""
        this.totalTurns = 0
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// CREW
// ══════════════════════════════════════════════════════════════════════════════

/// Classe Crew principal
class Crew {
    config: CrewConfig
    agents: Agent[]
    private agentMap: Map<Agent>

    constructor(name: string) {
        this.config = new CrewConfig()
        this.config.name = name
        this.agents = []
        this.agentMap = {}
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONFIGURAÇÃO
    // ══════════════════════════════════════════════════════════════════════════

    /// Define descrição
    setDescription(desc: string): Crew {
        this.config.description = desc
        return this
    }

    /// Define tipo de workflow
    setWorkflow(workflowType: WorkflowType): Crew {
        this.config.workflowType = workflowType
        return this
    }

    /// Define agent manager (para Hierarchical)
    setManager(agentName: string): Crew {
        this.config.managerAgent = agentName
        this.config.workflowType = WorkflowType.Hierarchical
        return this
    }

    /// Define quorum (para Consensus)
    setQuorum(quorum: i64): Crew {
        this.config.quorum = quorum
        return this
    }

    /// Adiciona um agent
    addAgent(agent: Agent): Crew {
        this.agents.push(agent)
        mapSet(this.agentMap, agent.config.name, agent)
        return this
    }

    /// Obtém agent por nome
    getAgent(name: string): Agent? {
        if (mapHas(this.agentMap, name)) {
            return mapGet(this.agentMap, name)
        }
        return null
    }

    // ══════════════════════════════════════════════════════════════════════════
    // EXECUÇÃO
    // ══════════════════════════════════════════════════════════════════════════

    /// Executa a crew
    run(task: string): CrewResult! {
        match (this.config.workflowType) {
            WorkflowType.Sequential => return try this.runSequential(task),
            WorkflowType.Parallel => return try this.runParallel(task),
            WorkflowType.Hierarchical => return try this.runHierarchical(task),
            WorkflowType.RoundRobin => return try this.runRoundRobin(task),
            WorkflowType.Consensus => return try this.runConsensus(task),
            _ => {
                let result: CrewResult = new CrewResult()
                result.error = "Unknown workflow type"
                return result
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WORKFLOWS
    // ══════════════════════════════════════════════════════════════════════════

    /// Execução sequencial
    private runSequential(task: string): CrewResult! {
        let result: CrewResult = new CrewResult()
        let currentInput: string = task
        let order: i64 = 0

        for (const agent of this.agents) {
            if (this.config.verbose) {
                log(`[Crew] Running agent: ${agent.config.name}`)
            }

            const agentResult: AgentResult = try agent.run(currentInput)
            result.agentOutputs.push(new AgentOutput(agent.config.name, agentResult, order))
            result.totalTurns = result.totalTurns + agentResult.turns

            if (!agentResult.success) {
                result.error = `Agent ${agent.config.name} failed: ${agentResult.error}`
                return result
            }

            // Output de um agent é input do próximo
            currentInput = agentResult.content
            order = order + 1
        }

        result.success = true
        result.finalOutput = currentInput
        return result
    }

    /// Execução paralela
    private runParallel(task: string): CrewResult! {
        let result: CrewResult = new CrewResult()

        // TODO: Usar threads reais quando disponível
        // Por enquanto, executa sequencialmente mas coleta todos os resultados
        let order: i64 = 0
        for (const agent of this.agents) {
            if (this.config.verbose) {
                log(`[Crew] Running agent in parallel: ${agent.config.name}`)
            }

            const agentResult: AgentResult = try agent.run(task)
            result.agentOutputs.push(new AgentOutput(agent.config.name, agentResult, order))
            result.totalTurns = result.totalTurns + agentResult.turns
            order = order + 1
        }

        // Combinar resultados
        let combined: string = "Results from all agents:\n\n"
        for (const output of result.agentOutputs) {
            combined = concat(combined, `## ${output.agentName}\n${output.result.content}\n\n`)
        }

        result.success = true
        result.finalOutput = combined
        return result
    }

    /// Execução hierárquica
    private runHierarchical(task: string): CrewResult! {
        let result: CrewResult = new CrewResult()

        // Obter manager
        if (len(this.config.managerAgent) == 0) {
            result.error = "No manager agent specified for hierarchical workflow"
            return result
        }

        if (!mapHas(this.agentMap, this.config.managerAgent)) {
            result.error = `Manager agent not found: ${this.config.managerAgent}`
            return result
        }

        const manager: Agent = mapGet(this.agentMap, this.config.managerAgent)

        // Manager decide como delegar
        const planPrompt: string = `You are coordinating a team of agents. Here are the available agents:
${this.listAgents()}

Task to complete: ${task}

Decide which agent(s) should handle which part of this task. Respond with a plan.`

        const plan: AgentResult = try manager.run(planPrompt)

        if (!plan.success) {
            result.error = `Manager failed to create plan: ${plan.error}`
            return result
        }

        // Por simplicidade, executa todos os agents com a tarefa original
        // TODO: Parsear o plano do manager e delegar apropriadamente
        return try this.runSequential(task)
    }

    /// Execução round-robin
    private runRoundRobin(task: string): CrewResult! {
        let result: CrewResult = new CrewResult()
        let currentInput: string = task
        let round: i64 = 0
        let agentIndex: i64 = 0

        while (round < this.config.maxRounds) {
            const agent: Agent = this.agents[agentIndex]

            if (this.config.verbose) {
                log(`[Crew] Round ${round + 1}, agent: ${agent.config.name}`)
            }

            // Preparar prompt com contexto
            let prompt: string = currentInput
            if (round > 0) {
                prompt = `Previous response: ${currentInput}\n\nContinue the task or indicate if complete.`
            }

            const agentResult: AgentResult = try agent.run(prompt)
            result.agentOutputs.push(new AgentOutput(agent.config.name, agentResult, round))
            result.totalTurns = result.totalTurns + agentResult.turns

            // Verificar se completou (simplificado)
            if (indexOf(toLower(agentResult.content), "complete") >= 0 ||
                indexOf(toLower(agentResult.content), "done") >= 0) {
                result.success = true
                result.finalOutput = agentResult.content
                return result
            }

            currentInput = agentResult.content
            agentIndex = (agentIndex + 1) % this.agents.len()
            round = round + 1
        }

        result.success = true
        result.finalOutput = currentInput
        return result
    }

    /// Execução por consenso
    private runConsensus(task: string): CrewResult! {
        let result: CrewResult = new CrewResult()

        // Cada agent vota
        let votes: Map<i64> = {}
        let order: i64 = 0

        for (const agent of this.agents) {
            if (this.config.verbose) {
                log(`[Crew] Getting vote from: ${agent.config.name}`)
            }

            const votePrompt: string = `${task}

Please provide your analysis and vote. End your response with either:
- VOTE: APPROVE
- VOTE: REJECT
- VOTE: ABSTAIN`

            const agentResult: AgentResult = try agent.run(votePrompt)
            result.agentOutputs.push(new AgentOutput(agent.config.name, agentResult, order))

            // Contar voto
            const content: string = toLower(agentResult.content)
            if (indexOf(content, "vote: approve") >= 0) {
                const current: i64 = mapGet(votes, "approve") catch 0
                mapSet(votes, "approve", current + 1)
            } else if (indexOf(content, "vote: reject") >= 0) {
                const current: i64 = mapGet(votes, "reject") catch 0
                mapSet(votes, "reject", current + 1)
            }

            order = order + 1
        }

        // Determinar resultado
        const approves: i64 = mapGet(votes, "approve") catch 0
        const rejects: i64 = mapGet(votes, "reject") catch 0
        const quorum: i64 = if (this.config.quorum > 0) { this.config.quorum } else { (this.agents.len() / 2) + 1 }

        result.success = approves >= quorum
        result.finalOutput = `Consensus result: ${approves} approves, ${rejects} rejects. Quorum: ${quorum}. Decision: ${if (result.success) { "APPROVED" } else { "REJECTED" }}`

        return result
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /// Lista agents disponíveis
    private listAgents(): string {
        let list: string = ""
        for (const agent of this.agents) {
            list = concat(list, `- ${agent.config.name}: ${agent.config.description}\n`)
        }
        return list
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// CREW BUILDER
// ══════════════════════════════════════════════════════════════════════════════

/// Builder para criar crews
class CrewBuilder {
    private crew: Crew

    constructor(name: string) {
        this.crew = new Crew(name)
    }

    /// Define descrição
    describe(desc: string): CrewBuilder {
        this.crew.setDescription(desc)
        return this
    }

    /// Define workflow
    workflow(wf: WorkflowType): CrewBuilder {
        this.crew.setWorkflow(wf)
        return this
    }

    /// Define workflow sequencial
    sequential(): CrewBuilder {
        this.crew.setWorkflow(WorkflowType.Sequential)
        return this
    }

    /// Define workflow paralelo
    parallel(): CrewBuilder {
        this.crew.setWorkflow(WorkflowType.Parallel)
        return this
    }

    /// Define workflow hierárquico
    hierarchical(manager: string): CrewBuilder {
        this.crew.setManager(manager)
        return this
    }

    /// Adiciona agent
    agent(a: Agent): CrewBuilder {
        this.crew.addAgent(a)
        return this
    }

    /// Habilita verbose
    verbose(): CrewBuilder {
        this.crew.config.verbose = true
        return this
    }

    /// Constrói a crew
    build(): Crew {
        return this.crew
    }
}

/// Inicia um builder de crew
fn crew(name: string): CrewBuilder {
    return new CrewBuilder(name)
}

// ══════════════════════════════════════════════════════════════════════════════
// CREWS PREDEFINIDAS
// ══════════════════════════════════════════════════════════════════════════════

/// Cria uma crew de code review
fn createCodeReviewCrew(): Crew {
    import { agent, createCodeAgent } from "./agent"

    // Reviewer
    const reviewer: Agent = agent("reviewer")
        .describe("Reviews code for bugs and issues")
        .system("You are a code reviewer. Find bugs, security issues, and suggest improvements.")
        .build()

    // Tester
    const tester: Agent = agent("tester")
        .describe("Suggests tests for the code")
        .system("You are a QA engineer. Suggest test cases and edge cases to test.")
        .build()

    // Documenter
    const documenter: Agent = agent("documenter")
        .describe("Improves documentation")
        .system("You are a technical writer. Improve comments and documentation.")
        .build()

    return crew("code-review")
        .describe("A team that reviews, tests, and documents code")
        .sequential()
        .agent(reviewer)
        .agent(tester)
        .agent(documenter)
        .build()
}

// ══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ══════════════════════════════════════════════════════════════════════════════

declare function log(msg: string): void;
declare function mapSet<T>(m: Map<T>, key: string, value: T): void;
declare function mapGet<T>(m: Map<T>, key: string): T;
declare function mapHas<T>(m: Map<T>, key: string): bool;
