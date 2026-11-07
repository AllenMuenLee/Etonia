"""Freeze synthetic calibration and held-out cases before any paid evaluation.

No learner data. Partition families are authored separately, rather than chosen
after seeing model answers. The manifest digest is used in the routing profile.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
cases = []


def add(kind, difficulty, partition, question, reference, text="", **extra):
    cases.append({"id": f"{kind}-{difficulty}-{partition}-{len(cases):03d}",
                  "kind": kind, "difficulty": difficulty, "partition": partition,
                  "question": question, "reference": reference, "text": text,
                  "title": "Course reference", "attachNotes": bool(text), **extra})


definitions = {
    (1, "calibration"): [
        ("What is a bit?", "A binary digit representing one of two values, conventionally zero and one."),
        ("What is a byte?", "In modern usage, a group of eight bits."),
        ("What is a transparent D latch?", "A level-sensitive one-bit store; while enabled Q follows D after delay, otherwise it holds its value."),
        ("What is a positive-edge D flip-flop?", "It samples D on a rising clock edge and holds Q between rising edges, assuming setup/hold requirements."),
        ("Define setup time for a flip-flop.", "The minimum time data must be stable before the active sampling edge."),
        ("Define hold time for a flip-flop.", "The minimum time data must remain stable after the active sampling edge."),
        ("What is metastability in a flip-flop?", "An unstable intermediate internal state with abnormally long settling; violation does not guarantee an opposite bit."),
        ("What is a stack data structure?", "Last in, first out; push and pop operate on the same end."),
        ("What is a queue data structure?", "First in, first out; enqueue and dequeue use logically opposite ends."),
        ("What is an integer?", "A whole number including zero and negative whole numbers; no fractional part."),
    ],
    (1, "heldout"): [
        ("What is binary search?", "Searches ordered data by repeatedly halving the candidate interval; logarithmic comparisons with random access."),
        ("What is a stable sorting algorithm?", "Preserves the original relative order of records having equal sort keys."),
        ("Define sampling frequency.", "The number of samples taken per unit time, usually samples per second or hertz."),
        ("What is aliasing in sampled signals?", "Different continuous frequencies can produce indistinguishable sample sequences; insufficient sampling can fold frequencies."),
        ("What is a series circuit connection?", "Components share a single current path, so the same current passes through them."),
        ("What is a parallel circuit connection?", "Components connect across the same pair of nodes and have the same voltage across them."),
        ("What is an ideal capacitor?", "Stores energy in an electric field; Q=CV and i=C dv/dt for constant capacitance."),
        ("What is an ideal inductor?", "Stores energy in a magnetic field; v=L di/dt for constant inductance."),
        ("Define the derivative of a function at a point.", "The limit of the difference quotient when it exists; the instantaneous rate of change or tangent slope."),
        ("What does algorithmic time complexity describe?", "How computational work scales with input size under a specified model; not the exact wall-clock runtime."),
    ],
    (2, "calibration"): [
        ("Explain how a D latch differs from a D flip-flop, including setup and hold time.", "Latch transparent while enabled; flip-flop samples an edge. Setup before, hold after capture; latch timing is around closing enable."),
        ("Explain the difference between a primary key and a foreign key in a relational database.", "Primary key uniquely identifies a row and is non-null; foreign key references a permitted key and enforces referential integrity subject to null rules."),
        ("Explain linear independence of a set of vectors.", "Only the all-zero coefficients make their linear combination zero; no vector is a redundant combination of the others in an independent set."),
        ("What is the difference between precision and recall in binary classification?", "Precision TP/(TP+FP); recall TP/(TP+FN). Mention undefined denominator handling if relevant; do not reverse them."),
        ("Explain the difference between resistance and impedance in AC circuits.", "Resistance is the real dissipative component; impedance is generally complex and includes reactance with magnitude and phase, depending on frequency."),
        ("What is the difference between compilation and interpretation?", "Compilation translates code before or during execution; interpretation executes via another program. JIT and hybrids exist; languages need not be inherently one or the other."),
        ("Explain conservation of energy in an ideal closed system.", "Total energy remains constant while changing forms; disappearance of useful mechanical energy can be conversion to heat rather than destruction."),
        ("What is the difference between lexical and semantic search?", "Lexical search matches words; semantic search matches representations of meaning. Neither guarantees relevance; hybrid can combine them."),
        ("Explain one's complement versus two's complement for signed binary integers.", "One's complement negates by bit inversion and has two zeros; two's complement adds one after inversion and has a single zero, with asymmetric signed range."),
        ("Explain necessary and sufficient conditions using implications.", "P sufficient for Q means P implies Q; P necessary for Q means Q implies P; both means equivalence."),
    ],
    (2, "heldout"): [
        ("Explain causality versus BIBO stability for a discrete-time system.", "Causality means no dependence on future input; BIBO stability means every bounded input yields bounded output. Neither implies the other in general."),
        ("What is the relationship between a square matrix's determinant and invertibility?", "Over a field, a square matrix is invertible exactly when its determinant is nonzero; determinant zero means singular."),
        ("Explain serial versus parallel loading of a register.", "Serial transfers bits sequentially through a serial input; parallel loading captures multiple bits together on the loading event."),
        ("Does negative feedback always make a system stable? Explain.", "No. Loop gain, phase shift, dynamics and delays matter; nominal negative feedback can become reinforcing at relevant frequencies."),
        ("What is the difference between an ideal open circuit and an ideal short circuit?", "Open circuit carries zero current but may have voltage; ideal short has zero voltage but may carry current. Do not reverse these."),
        ("What does a p-value mean, and is it the probability the null hypothesis is true?", "It measures probability under the null model of outcomes at least as extreme by the specified test; not the probability the null is true."),
        ("Explain covariance versus correlation.", "Covariance measures joint variation in units of the variables; Pearson correlation normalizes by standard deviations and is unitless, undefined for zero variance."),
        ("What is the difference between prompt caching and retrieval in an AI application?", "Prompt caching reuses computation for repeated input prefixes; retrieval selects relevant external evidence. Caching does not guarantee the answer itself is reused."),
        ("Explain blocking versus nonblocking I/O.", "Blocking waits for an operation to become ready/complete; nonblocking returns promptly with available progress or an indication it would block. Async is related but not identical."),
        ("What is the difference between an idempotent operation and a pure function?", "Repeated idempotent application has the same relevant effect as one application; purity concerns deterministic results and absence of observable side effects. They are different properties."),
    ],
}
for (difficulty, partition), rows in definitions.items():
    for question, reference in rows:
        add("definition", difficulty, partition, question, reference)

calculations = {
    (1, "calibration"): [
        ("Calculate 17 + 28.", "45."),
        ("Calculate the current through a 4 kilo-ohm resistor at 12 V.", "0.003 A = 3 mA, not 3 A."),
        ("Solve 3x + 5 = 20.", "x = 5."),
        ("Differentiate x squared with respect to x.", "2x."),
        ("Convert binary 101101 to decimal.", "45."),
        ("Calculate 15 percent of 240.", "36."),
        ("Simplify 2/3 + 1/6.", "5/6."),
        ("Evaluate log base two of 32.", "5."),
        ("Calculate the area of a circle of radius 3, leaving pi exact.", "9 pi square units."),
        ("Solve 2(x - 4) = 10.", "x = 9."),
    ],
    (1, "heldout"): [
        ("Evaluate 6 factorial.", "720."),
        ("Calculate how many ways there are to choose two items from five distinct items.", "10 unordered selections without replacement."),
        ("Convert hexadecimal 2F to decimal.", "47."),
        ("Evaluate Boolean A AND B when A is 1 and B is 0.", "0."),
        ("Simplify 7/8 - 1/4.", "5/8."),
        ("Calculate the voltage across a 220-ohm resistor carrying 10 mA.", "2.2 V."),
        ("Calculate the mean of 4, 7, and 10.", "7."),
        ("Convert 250 milliseconds to seconds.", "0.25 seconds."),
        ("Evaluate the square root of 81 over the real numbers.", "The principal square root is 9; do not confuse with solving x squared equals 81."),
        ("Solve x/5 = 7.", "x = 35."),
    ],
    (2, "calibration"): [
        ("Solve log_2(x-1) + log_2(x-3) = 3 over the reals, including the domain.", "Domain x > 3. Candidates 5 and -1; only 5 is valid. Reject -1 because the separate log arguments are negative."),
        ("Solve x squared minus 5x plus 6 equals zero.", "x = 2 or x = 3."),
        ("Differentiate x squared times sin(x), showing the rule used.", "Product rule: 2x sin(x) + x squared cos(x)."),
        ("Calculate the equivalent resistance of 6 ohms and 3 ohms in parallel.", "2 ohms, using reciprocals."),
        ("Solve the system x+y=7 and x-y=1.", "x=4, y=3."),
        ("Evaluate the definite integral of 2x from zero to three.", "9."),
        ("Calculate the probability of exactly two heads in three independent fair coin tosses.", "3/8."),
        ("Calculate the RMS voltage of a sinusoid whose peak amplitude is 10 V and whose DC offset is zero.", "10/sqrt(2) V, approximately 7.071 V."),
        ("Solve the inequality -2x + 3 > 7.", "x < -2; reverse the inequality when dividing by -2."),
        ("Simplify Boolean A B + A NOT B and identify the law.", "A, using distributivity and B OR NOT B = 1."),
    ],
    (2, "heldout"): [
        ("Solve sqrt(x+1) = x-1 over the reals and reject extraneous candidates.", "x >= 1 initially. Squaring gives candidates 0 and 3. Only 3 satisfies the original equation."),
        ("Calculate the determinant of the matrix with rows [2,3] and [1,4].", "5."),
        ("Differentiate ln(3x+1) and state its real domain.", "Derivative 3/(3x+1), original real domain x > -1/3."),
        ("Calculate the total capacitance of 6 microfarads and 3 microfarads in series.", "2 microfarads."),
        ("Solve 2x+y=11 and x-y=1.", "x=4, y=3."),
        ("Evaluate the limit of sin(x)/x as x tends to zero in radians.", "1."),
        ("Calculate P(A given B) if P(A and B)=0.12 and P(B)=0.3.", "0.4, since conditional probability is the intersection divided by P(B)."),
        ("Calculate the slope and y-intercept of the line through (1,3) and (3,7).", "Slope 2 and intercept 1; y=2x+1."),
        ("Solve absolute value of x minus two less than three.", "If the expression is |x-2| < 3, then -1 < x < 5. State that interpretation."),
        ("Evaluate a positive-edge D flip-flop: Q starts 0, D is 1 at the rising edge, then D becomes 0 before the falling edge. What is Q after falling?", "Q=1 if timing requirements are met; the falling edge does not sample D."),
    ],
}
for (difficulty, partition), rows in calculations.items():
    for question, reference in rows:
        add("calculation", difficulty, partition, question, reference)

filler = [
    "Pottery notes describe shaping clay by hand and drying it before firing. Surface glazes affect the finish. The craft requires careful handling and familiarity with different materials. This is a separate topic from the course reference below.",
    "Botanical fieldwork records the shape of leaves and the texture of bark. Observers compare samples from shaded and sunny locations. A field notebook should distinguish direct observations from interpretations about the surrounding habitat.",
    "Music practice includes listening closely to rhythm and phrasing. Students benefit from slow repetition and short focused sessions. This paragraph concerns rehearsal techniques and contains no device settings or protocol requirements.",
    "Historical reading compares accounts from different writers. A useful annotation records the argument and the evidence supporting it. The surrounding cultural setting helps explain terminology without changing what the primary account states.",
    "Drawing practice develops control of line weight and composition. Artists can use light construction strokes before committing to an outline. These observations concern studio technique rather than the operating rules in the reference material.",
    "A language journal can collect new vocabulary and examples of ordinary usage. Context helps distinguish related meanings, while repeated review improves recall. This paragraph provides background study advice and does not define a protocol exception.",
    "Library organization groups related resources and preserves their provenance. Descriptive catalogues help readers find an item again. A well organized collection does not imply that every item is relevant to every question asked about it.",
]

lookups = {
    "calibration": [
        ("Aster", "The Aster module's reset code is KESTREL.", "reset code", "KESTREL"),
        ("Birch", "The Birch protocol's acknowledgement word is AMBER.", "acknowledgement word", "AMBER"),
        ("Cobalt", "The Cobalt course board labels its output as ZETA.", "output label", "ZETA"),
        ("Dahlia", "The Dahlia sample must be stored in the GREEN tray.", "storage tray", "GREEN"),
        ("Elm", "The Elm exercise defines its origin as station NORTH.", "origin station", "NORTH"),
        ("Finch", "The Finch schema names its identifier field parcel_key.", "identifier field", "parcel_key"),
        ("Garnet", "The Garnet handout calls the enabled state READY.", "enabled state", "READY"),
        ("Hazel", "The Hazel study group meets in room HAWK.", "meeting room", "HAWK"),
        ("Iris", "The Iris fixture's reference direction is WEST.", "reference direction", "WEST"),
        ("Juniper", "The Juniper experiment uses the label QUIET for its resting mode.", "resting mode label", "QUIET"),
    ],
    "heldout": [
        ("Kite", "The Kite specification calls its terminating symbol ORBIT.", "terminating symbol", "ORBIT"),
        ("Larch", "The Larch workbook assigns the review activity to folder SABLE.", "review folder", "SABLE"),
        ("Mica", "The Mica setup names its calibration port DELTA.", "calibration port", "DELTA"),
        ("Nettle", "The Nettle protocol records successful delivery as COPPER.", "successful-delivery label", "COPPER"),
        ("Onyx", "The Onyx notes call the final processing phase HARBOR.", "final phase name", "HARBOR"),
        ("Pine", "The Pine schema stores its reference code in beacon_id.", "reference-code field", "beacon_id"),
        ("Quartz", "The Quartz course device names its warning state VIOLET.", "warning state", "VIOLET"),
        ("Reed", "The Reed experiment requires the sample container marked SILVER.", "sample container", "SILVER"),
        ("Spruce", "The Spruce lesson uses MAPLE as its anchor keyword.", "anchor keyword", "MAPLE"),
        ("Tern", "The Tern reference sheet names its standby signal MIST.", "standby signal", "MIST"),
    ],
}
for partition, rows in lookups.items():
    for name, fact, field, answer in rows:
        paragraphs = ["Course reference", *filler[:3], fact, *filler[3:]]
        add("sourceLookup", 1, partition,
            f"According to my notes for {name}, what is the {field}?",
            f"The answer must be {answer}, from the supplied {name} reference. Cite that source; do not substitute general knowledge.",
            "\n\n".join(paragraphs))

conditional = {
    "calibration": [
        ("Umber", "Umber signals READY only when TOKEN is present and ENABLE is high.", "Umber RESET overrides all other inputs and forces READY low.", "TOKEN is present and ENABLE is high, but RESET is active. Is READY high?", "No. RESET forces READY low."),
        ("Vale", "Vale packets are accepted only when the checksum is good and the tag is BLUE.", "Vale's emergency flag does not waive the BLUE-tag requirement.", "The checksum is good, the tag is GREEN, and emergency is set. Is the packet accepted?", "No. The tag must still be BLUE."),
        ("Willow", "Willow editing requires both an editor role and an OPEN document.", "Willow archived documents cannot be edited even by an editor.", "An editor opens an archived document. Is editing allowed?", "No, archived documents cannot be edited."),
        ("Xenia", "Xenia samples are valid only when they are labelled and sealed.", "Xenia damaged seals invalidate a sample regardless of its label.", "The label is present but the seal is damaged. Is this a valid sample?", "No. A damaged seal invalidates it."),
        ("Yarrow", "Yarrow runs begin only after preparation and inspection are complete.", "Yarrow's supervisor signature cannot replace the inspection.", "Preparation and supervisor signature are complete, but inspection is absent. May the run begin?", "No. Inspection remains required."),
        ("Zephyr", "Zephyr delivery requires a destination and an acknowledgement.", "Zephyr cancelled items are never delivered.", "Both destination and acknowledgement exist, but the item is cancelled. Will it be delivered?", "No. Cancellation prevents delivery."),
        ("Acorn", "Acorn export requires an approved format and a readable source.", "Acorn encryption without a decryption key makes a source unreadable.", "The format is approved but the encrypted source has no key. Can it be exported?", "No. The source is not readable."),
        ("Bracken", "Bracken grants access to members who have completed orientation.", "Bracken suspended members have no access until suspension ends.", "A suspended member has completed orientation. Is access granted?", "No. Suspension blocks access."),
        ("Cedar", "Cedar schedules a session after a room and a tutor are confirmed.", "Cedar room cancellations remove the confirmation.", "A tutor is confirmed, but the room was cancelled. Is the session scheduled?", "No. The room is no longer confirmed."),
        ("Dune", "Dune releases a result when review is complete and the status is FINAL.", "Dune corrections return the status to DRAFT.", "Review is complete but a correction returned the status to DRAFT. Is it released?", "No. FINAL status is still needed."),
    ],
    "heldout": [
        ("Ember", "Ember records can be deleted by an owner while the collection is ACTIVE.", "Ember legal holds block deletion for every role.", "The owner controls an ACTIVE collection under a legal hold. Can the record be deleted?", "No. The hold blocks deletion."),
        ("Frost", "Frost accepts commands when a session is authenticated and a channel is connected.", "Frost expired credentials mean the session is no longer authenticated.", "The channel remains connected but the credentials expired. Is a command accepted?", "No. Authentication is no longer valid."),
        ("Grove", "Grove marks work complete when all required sections are submitted.", "Grove optional appendices are not required sections.", "All required sections are submitted but an optional appendix is absent. Is the work complete?", "Yes. The optional appendix is not required."),
        ("Heath", "Heath enables a sensor when its battery is charged and its cover is closed.", "Heath maintenance mode disables the sensor regardless of battery and cover.", "The battery is charged, the cover is closed, and maintenance mode is on. Is the sensor enabled?", "No. Maintenance mode disables it."),
        ("Islet", "Islet passes a batch when its temperature is normal and its seal is intact.", "Islet labels cannot override an abnormal temperature.", "The label is correct and the seal intact, but temperature is abnormal. Does it pass?", "No. Temperature must be normal."),
        ("Jade", "Jade makes a task eligible after its prerequisites are complete.", "Jade paused tasks remain ineligible even after prerequisite completion.", "Prerequisites are complete but the task is paused. Is it eligible?", "No. Paused tasks are ineligible."),
        ("Knoll", "Knoll's ACTIVE flag authorizes ordinary reads.", "Knoll's freeze flag blocks writes only; it does not block ordinary reads.", "ACTIVE and freeze are both set. Are ordinary reads authorized?", "Yes. Freeze blocks writes, not reads."),
        ("Lagoon", "Lagoon accepts a form with a name and a valid signature.", "Lagoon's optional nickname may be left blank.", "The form has a name and valid signature, but no nickname. Is it accepted?", "Yes. Nickname is optional."),
        ("Moss", "Moss marks a signal valid when its timing and parity checks pass.", "Moss parity errors invalidate a signal even if timing passes.", "Timing passes but parity fails. Is the signal valid?", "No. Both checks must pass."),
        ("Nacre", "Nacre restores a session when a snapshot exists and its checksum matches.", "Nacre a matching title is not a substitute for a checksum match.", "A snapshot and matching title exist, but its checksum differs. Is the session restored?", "No. A matching checksum is required."),
    ],
}
for partition, rows in conditional.items():
    for name, rule, exception, question, reference in rows:
        paragraphs = ["Course reference", *filler[:2], rule, *filler[2:5], exception, *filler[5:]]
        add("sourceLookup", 2, partition,
            f"According to my notes for {name}, {question[0].lower() + question[1:]}",
            reference + " Ground the decision in both the rule and its exception; cite the supplied source.",
            "\n\n".join(paragraphs))

# Out-of-scope sentinels: these must not qualify for the cheap bounded-text route.
hard = [
    ("Prove by induction that the sum of the first n odd positive integers is n squared.", "Base case n=1; add 2n+1 to n squared to get (n+1) squared."),
    ("Derive the energy stored in an ideal capacitor from charge and voltage.", "Integrate v dq with v=q/C from 0 to Q to get Q squared/(2C)=CV squared/2."),
    ("Derive the continuous Fourier transform of exp(-a t) u(t) for real a>0, using exp(-j omega t).", "Integral from zero to infinity yields 1/(a+j omega), convergence requires a>0."),
    ("Prove that the square root of two is irrational.", "Assume a reduced integer ratio; squaring makes numerator even, then denominator even, contradicting coprimality."),
    ("Calculate eigenvalues of the diagonal matrix with diagonal entries 2 and 3.", "2 and 3."),
    ("Solve the differential equation y'=y with y(0)=2.", "y=2 exp(t)."),
    ("Prove that the derivative of a differentiable even function is odd wherever the reflected points are in its domain.", "Differentiate f(-x)=f(x); chain rule gives -f'(-x)=f'(x)."),
    ("Derive the Laplace transform of the constant one for t>=0.", "1/s, region Re(s)>0."),
    ("Prove that a real square matrix with a nonzero determinant is invertible.", "Use adjugate identity A adj(A)=det(A)I; divide by nonzero determinant."),
    ("Derive the voltage across a charging RC capacitor from zero under a DC step V.", "v_C(t)=V(1-exp(-t/(RC))) under the ideal series RC assumptions, with time constant RC."),
]
for i, (question, reference) in enumerate(hard):
    add("sentinel", 3, "heldout" if i % 2 else "calibration", question, reference)

lesson = {"topic": "Algebra", "activeStep": 0, "stage": "learning", "steps": [
    {"title": "Variables", "goal": "Understand a variable as a placeholder", "retrievalQuery": "variables placeholder", "foundationExercise": "If x is two, what is x plus one?"},
    {"title": "Equations", "goal": "Keep both sides equal", "retrievalQuery": "equations balance", "foundationExercise": "Solve x + 1 = 3."},
]}
for i, question in enumerate(["next", "next step", "I do not understand what a variable represents.",
                              "What is a coefficient?", "Could you explain the current example again?",
                              "Can you give another foundational example?", "Why do both sides have to stay equal?",
                              "What does x stand for here?", "How do I know which step to try?", "I think x is always one."]):
    reference = ("Continue at Equations, teach one stage and give one short understanding check; do not jump to a final test."
                 if question in ("next", "next step") else
                 "Respond constructively to the current question while preserving the lesson position. Do not start a new roadmap or final test. Explain terms simply; do not attribute an unshown mistake to the student.")
    add("sentinel", 3, "heldout" if i % 2 else "calibration", question, reference,
        "Variables are placeholders for numbers. Equations balance equal expressions.",
        plan=lesson, history=[{"role": "user", "text": "Teach me algebra from the basics."},
                             {"role": "assistant", "text": "We will start with variables, then equations. A variable is a placeholder for a number. If x is two, what is x plus one?"}])

for question, reference in [
    ("计算函数 f(x)=x² 的导数。", "The derivative is 2x; explain in Chinese."),
    ("电阻为四千欧，电压为十二伏，计算电流并给出单位。", "3 mA = 0.003 A, not 3 A; explain in Chinese."),
    ("解释 D 触发器的建立时间和保持时间。", "Setup is before the active edge; hold is after; explain in Chinese."),
    ("正边沿 D 触发器在上升沿时 D 为一，下降沿之前 D 变成零。满足时序要求时，下降沿之后 Q 是多少？", "Q remains one; falling edge does not capture; explain in Chinese."),
    ("求实数方程 log_2(x-1)+log_2(x-3)=3 的定义域和解。", "Domain x>3; only solution x=5; reject x=-1; explain in Chinese."),
    ("¿Qué es un bit?", "A binary digit with two possible values; answer in Spanish."),
    ("¿Cuál es la derivada de x² respecto de x?", "2x; answer in Spanish."),
    ("¿Cuál es la corriente con doce voltios y cuatro kiloohmios?", "3 mA = 0.003 A; answer in Spanish."),
    ("¿Cuál es la diferencia entre precisión y exhaustividad en clasificación binaria?", "Precision TP/(TP+FP); recall TP/(TP+FN); explain in Spanish."),
    ("¿Un circuito abierto ideal tiene necesariamente voltaje cero?", "No. It has zero current; voltage can be nonzero. Explain in Spanish."),
]:
    add("sentinel", 3, "heldout", question, reference)

assert len(cases) == 150
for kind in ("definition", "calculation", "sourceLookup"):
    for difficulty in (1, 2):
        for partition in ("calibration", "heldout"):
            assert sum(c["kind"] == kind and c["difficulty"] == difficulty and c["partition"] == partition for c in cases) == 10
out = ROOT / "supabase/evals/study_cost/cases.json"
out.parent.mkdir(parents=True, exist_ok=True)
encoded = json.dumps(cases, indent=2, ensure_ascii=False) + "\n"
out.write_text(encoded, encoding="utf-8")
print(f"Wrote {len(cases)} synthetic cases; SHA256 {hashlib.sha256(encoded.encode()).hexdigest()}")
