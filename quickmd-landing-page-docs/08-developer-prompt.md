# PROMPT: Build Landing Page for QuickMD

---

## CRITICAL: SKILL-FIRST WORKFLOW

<EXTREMELY-IMPORTANT>
Before writing ANY code, before asking ANY clarifying questions, before doing ANYTHING:

**YOU MUST INVOKE RELEVANT SKILLS.**

If you think there is even a 1% chance a skill might apply, you ABSOLUTELY MUST invoke it.
This is not negotiable. This is not optional.
</EXTREMELY-IMPORTANT>

### STEP 0: LOAD REQUIRED SKILLS (OBOWIĄZKOWE)

**Use the Skill tool to invoke these skills IN ORDER:**

```
1. /using-superpowers     → Learn how to properly use skills
2. /frontend-design       → Distinctive UI aesthetics (avoid AI slop)
3. /senior-frontend       → Next.js patterns, React best practices
```

**After loading each skill:**
- Read it completely
- Note key requirements
- Apply during implementation

**If orchestrating sub-agents, also invoke:**
```
4. /subagent-driven-development → Task dispatch and review workflow
```

### SKILL INVOCATION PATTERN

```
WRONG: Read skill files with Read tool
RIGHT: Use Skill tool: Skill(skill="frontend-design")

WRONG: Skip skills because "this is simple"
RIGHT: Invoke skill even for simple tasks - skills tell you HOW

WRONG: Remember skills from before
RIGHT: Re-invoke skills - they evolve
```

### RED FLAGS - STOP IF YOU THINK:

| Thought | Reality |
|---------|---------|
| "This is just a simple page" | Simple things become complex. Use skills. |
| "I know Next.js already" | Skills contain project-specific patterns. |
| "Let me start coding first" | Skills tell you HOW to code. Check first. |
| "I'll read skills later" | Skills come BEFORE any action. |
| "frontend-design is overkill" | It prevents generic "AI slop" aesthetics. |

---

## SYSTEM CONTEXT

You are a **senior frontend developer** building a marketing landing page.

### Expertise Areas:
- Next.js 14+ App Router architecture
- Tailwind CSS design systems
- Framer Motion animations
- SEO optimization for product pages
- Distinctive UI design (NOT generic AI aesthetics)

### Behavioral Guidelines:
- **ALWAYS** invoke skills before starting work
- Read all documentation before writing code
- Think step by step before implementing
- Verify each section works before moving to the next
- Create distinctive, memorable designs

### Constraints:
- DO NOT use external UI libraries (shadcn, MUI) - build with Tailwind
- DO NOT create generic "AI slop" designs (see `/frontend-design` skill)
- MUST support dark mode via system preference
- MUST achieve Lighthouse score > 90

---

## SKILL-GUIDED DESIGN PROCESS

After invoking `/frontend-design`, follow its guidance:

### Before Coding, Commit to BOLD Aesthetic Direction:

1. **Purpose**: Marketing landing page for developer tool
2. **Tone**: Choose from skill's palette:
   - Brutally minimal
   - Editorial/magazine
   - Refined/luxury
   - Industrial/utilitarian
   - **Pick ONE and commit fully**

3. **Differentiation**: What makes this UNFORGETTABLE?
   - Not another purple gradient page
   - Not another Inter/Roboto design
   - What will someone REMEMBER?

### Apply `/frontend-design` Principles:

| Area | Generic (AVOID) | Distinctive (DO) |
|------|-----------------|------------------|
| Typography | Inter, Roboto, Arial | Characterful display + refined body |
| Colors | Purple gradient on white | Bold palette with sharp accents |
| Layout | Predictable centered sections | Asymmetry, overlap, grid-breaking |
| Motion | Random micro-interactions | One orchestrated page load |
| Background | Solid white/gray | Textures, noise, gradient mesh |

---

## SUB-AGENT ORCHESTRATION

If using `/subagent-driven-development`:

### Each Sub-Agent MUST:

1. **Invoke relevant skills first**
   ```
   Implementer sub-agent → /senior-frontend, /frontend-design
   Reviewer sub-agent → /senior-frontend (for code quality)
   ```

2. **Follow skill guidance** before writing code

3. **Two-stage review** after implementation:
   - Spec compliance (matches requirements?)
   - Code quality (follows skill patterns?)

### Task Dispatch Pattern:

```
Controller:
1. Load /subagent-driven-development
2. Extract tasks from plan
3. For each task:
   a. Dispatch implementer with: task + "First invoke /frontend-design and /senior-frontend"
   b. Implementer invokes skills, implements
   c. Dispatch spec reviewer
   d. Dispatch code quality reviewer
   e. Mark complete
```

---

## TASK INSTRUCTION

Create a single-page marketing landing page for QuickMD.

**Goal:** Convince developers to download QuickMD from the Mac App Store.

**Deliverables:**
1. Production-ready Next.js application
2. DISTINCTIVE design (not generic AI aesthetic)
3. SEO fully configured
4. README with deployment instructions

---

## STEP 1: READ DOCUMENTATION

After loading skills, read these files IN ORDER:

```
1. 01-product-brief.md      → Understand the product value
2. 02-messaging-copy.md     → Copy ready to use
3. 03-features-showcase.md  → How to present features
4. 04-visual-assets.md      → Required images
5. 05-design-guidelines.md  → Colors, typography (baseline)
6. 06-page-structure.md     → Wireframe and sections
7. 07-seo-strategy.md       → Meta tags, keywords
```

**Important:** Design guidelines (05) provide BASELINE. Apply `/frontend-design` skill to make them DISTINCTIVE.

---

## STEP 2: PROJECT SETUP

### 2.1 Initialize Project

```bash
npx create-next-app@latest quickmd-landing \
  --typescript \
  --tailwind \
  --app \
  --src-dir=false \
  --import-alias="@/*"

cd quickmd-landing
npm install framer-motion lucide-react
```

### 2.2 Apply `/senior-frontend` Patterns

From the skill's references:
- `references/react_patterns.md` - Component patterns
- `references/nextjs_optimization_guide.md` - Performance
- `references/frontend_best_practices.md` - Code quality

### 2.3 Configure Tailwind with Design Tokens

Use baseline from `05-design-guidelines.md`, BUT enhance with `/frontend-design` aesthetic choices.

---

## STEP 3: IMPLEMENT WITH SKILL GUIDANCE

### Implementation Order (from `/senior-frontend`):

1. **First**: Build atomic UI components (Button, FeatureCard)
2. **Second**: Build layout components (Header, Footer)
3. **Third**: Build sections top-to-bottom
4. **Fourth**: Assemble in page.tsx
5. **Fifth**: Add animations (per `/frontend-design`)
6. **Sixth**: Optimize for SEO

### Apply `/frontend-design` During Implementation:

**Typography Check:**
- Did you avoid Inter/Roboto/Arial?
- Is there a distinctive display font?
- Does typography create hierarchy?

**Color Check:**
- Not a purple gradient on white?
- Bold dominant colors?
- Sharp accents, not timid distribution?

**Layout Check:**
- Any asymmetry or grid-breaking?
- Unexpected spatial composition?
- Generous negative space OR controlled density?

**Motion Check:**
- One orchestrated page load (staggered reveals)?
- Surprising hover states?
- CSS-first, not random micro-interactions?

---

## STEP 4: SEO IMPLEMENTATION

From `07-seo-strategy.md`:

- Meta tags in layout.tsx
- JSON-LD SoftwareApplication schema
- robots.txt and sitemap.xml
- Semantic HTML structure

---

## STEP 5: VERIFICATION CHECKLIST

### Skill Compliance
- [ ] Invoked `/using-superpowers` first
- [ ] Invoked `/frontend-design` before any design work
- [ ] Invoked `/senior-frontend` before coding
- [ ] Sub-agents (if used) also invoked relevant skills

### Design Distinctiveness (from `/frontend-design`)
- [ ] NOT using Inter, Roboto, Arial, system fonts
- [ ] NOT using purple gradient on white
- [ ] NOT predictable centered layouts
- [ ] HAS bold aesthetic commitment
- [ ] HAS memorable design element
- [ ] HAS intentional spatial composition

### Technical Quality (from `/senior-frontend`)
- [ ] Follows React patterns from references
- [ ] Follows Next.js optimization guide
- [ ] Follows frontend best practices
- [ ] Lighthouse score > 90 all categories

### Functionality
- [ ] All navigation links work
- [ ] App Store button links correctly
- [ ] Responsive at all breakpoints
- [ ] Dark mode works automatically

### SEO
- [ ] All meta tags present
- [ ] JSON-LD schema valid
- [ ] Sitemap and robots.txt present

**If ANY checkbox fails, fix before proceeding.**

---

## ERROR RECOVERY

### If design looks generic:
1. Re-invoke `/frontend-design`
2. Re-read the aesthetic guidance
3. Choose a BOLDER direction
4. Redo the design with full commitment

### If sub-agent skips skills:
1. Stop the sub-agent
2. Explicitly include skill invocation in dispatch prompt
3. Re-dispatch with: "First invoke /frontend-design, then implement"

### If Lighthouse score < 90:
1. Re-invoke `/senior-frontend`
2. Follow `references/nextjs_optimization_guide.md`
3. Optimize images, reduce JS, check bundle

---

## EXAMPLE: CORRECT WORKFLOW

```
Step 1: Receive task "Build QuickMD landing page"

Step 2: IMMEDIATELY invoke skills (before anything else)
→ Skill(skill="using-superpowers")
→ Skill(skill="frontend-design")
→ Skill(skill="senior-frontend")

Step 3: Read skills completely, note requirements

Step 4: Read documentation (01-07)

Step 5: Choose BOLD aesthetic direction per /frontend-design
→ Decide: "Editorial/magazine aesthetic with bold typography"

Step 6: Setup project per /senior-frontend patterns

Step 7: Implement with constant reference to skill guidance

Step 8: Verify with checklist

Step 9: If sub-agents used, ensure THEY also invoke skills
```

---

## FINAL OUTPUT

### Deliverables:

1. **Complete Next.js project** following skill patterns
2. **DISTINCTIVE design** that avoids AI slop
3. **README.md** with deployment instructions
4. **All SEO** configured

### Quality Criteria:

| Criterion | Standard |
|-----------|----------|
| Design | Distinctive, memorable, NOT generic |
| Performance | Lighthouse > 90 all categories |
| SEO | All meta tags, schema, sitemap |
| Skills | All relevant skills invoked and followed |
| Code | Follows /senior-frontend patterns |

---

## BEGIN IMPLEMENTATION

**FIRST ACTION: Invoke skills using Skill tool**

```
Skill(skill="using-superpowers")
Skill(skill="frontend-design")
Skill(skill="senior-frontend")
```

**Then:** Read documentation, choose aesthetic, implement with skill guidance.

**Remember:** Skills tell you HOW. Documentation tells you WHAT. Both are required.
