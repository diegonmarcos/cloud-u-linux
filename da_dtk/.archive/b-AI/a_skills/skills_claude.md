# Claude Code Skills Reference

> Custom skills for Claude Code CLI
> **Source**: [github.com/anthropics/skills](https://github.com/anthropics/skills)
> **Updated**: 2025-12-29

---

## What Are Skills?

Skills are folders of instructions, scripts, and resources that Claude loads dynamically to improve performance on specialized tasks. They teach Claude how to complete specific tasks repeatably.

**Use Cases:**
- Creating documents with company brand guidelines
- Analyzing data using organizational workflows
- Automating personal tasks
- Creative applications (art, music, design)
- Technical tasks (testing web apps, MCP server generation)
- Enterprise workflows (communications, branding)

---

## Skill File Structure

Each skill is a self-contained folder with a `SKILL.md` file:

```markdown
---
name: my-skill-name
description: A clear description of what this skill does and when to use it
---

# My Skill Name

[Instructions Claude will follow when this skill is active]

## Examples
- Example usage 1
- Example usage 2

## Guidelines
- Guideline 1
- Guideline 2
```

### Required Frontmatter Fields

| Field | Description |
|-------|-------------|
| `name` | Unique identifier (lowercase, hyphens for spaces) |
| `description` | Complete description of what the skill does and when to use it |

---

## Using Skills in Claude Code

### Register the Official Repository

```bash
/plugin marketplace add anthropics/skills
```

### Install Skills

**Interactive:**
1. Select `Browse and install plugins`
2. Select `anthropic-agent-skills`
3. Choose `document-skills` or `example-skills`
4. Select `Install now`

**Direct install:**
```bash
/plugin install document-skills@anthropic-agent-skills
/plugin install example-skills@anthropic-agent-skills
```

### Invoke a Skill

Mention the skill in your request:
> "Use the PDF skill to extract form fields from `path/to/file.pdf`"

---

## Official Skill Categories

| Category | Examples |
|----------|----------|
| **Creative & Design** | Art, music, design tasks |
| **Development & Technical** | Testing, MCP server generation |
| **Enterprise & Communication** | Communications, branding |
| **Document Skills** | DOCX, PDF, PPTX, XLSX manipulation |

---

## Repository Structure

```
anthropics/skills/
├── skills/      # Skill examples
├── spec/        # Agent Skills specification
└── template/    # Skill template for creating new skills
```

---

## Skill Locations

| Location | Scope |
|----------|-------|
| `~/.claude/skills/` | Global (all projects) |
| `./.claude/skills/` | Project-specific |
| Plugin marketplace | Shared/community skills |

---

## Integration with Agent Personas

Skills can be combined with agent personas from [skills.md](./skills.md):

| Persona | Recommended Skills |
|---------|-------------------|
| frontend-developer | document-skills, testing |
| backend-architect | MCP server generation |
| devops-automator | automation, deployment |
| content-creator | document-skills, branding |

---

## Platform Availability

| Platform | Access |
|----------|--------|
| **Claude Code** | Via plugin marketplace |
| **Claude.ai** | Available to paid plans |
| **Claude API** | Pre-built or custom skills via API |

---

## Official Resources

- [What are skills?](https://support.claude.com/en/articles/12512176-what-are-skills)
- [Using skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)
- [Creating custom skills](https://support.claude.com/en/articles/12512198-creating-custom-skills)
- [Agent Skills Standard](http://agentskills.io)
- [Skills API Quickstart](https://docs.claude.com/en/api/skills-guide#creating-a-skill)
- [GitHub Repository](https://github.com/anthropics/skills)

---

## Related Files

- [Agent Personas](./skills.md) - AI persona definitions
