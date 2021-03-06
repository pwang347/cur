#lang scribble/base
@(require
  scribble/manual
  scriblib/figure
  "defs.rkt"
  "bib.rkt")

@title*{Tactics}
In this section we describe a tactic system called @emph{ntac} implemented in
Cur.
We begin with an example of using the tactic system to prove a trivial theorem:
@racketblock[
ntac $ forall (A : Type) (a : A) A
  by-intro A
  by-intro b
  by-assumption
]
This example shows the type of the polymorphic identity function written using tactics.
We use @racket[ntac], a form that builds an expression given an initial goal
followed by a tactic script.
This is similar to @code{Goal} in Coq, which introduces an anonymous goal that
can be solved using an Ltac script.
In this example we use the @racket[by-intro] tactic, which takes a single optional argument
representing the name to bind as an assumption in the local proof environment.
Then we conclude the proof with @racket[by-assumption], which takes no
arguments and searches the local environment for a term that matches the
current goal.
Since all goals are complete at this point, we end the proof.

@racketblock[
define-theorem id $ forall (A : Type) (a : A) A
  by-obvious
]
We can also use @racket[define-theorem] to define a new identifier using an ntac script.
The form @racket[(define-theorem name goal script ...)] is simply syntax sugar
for @racket[(define name (ntac goal script ...))].
In this example, we use the @racket[by-obvious] tactic which solves certain
trivial theorems.

We begin implementing ntac by implementing the @racket[ntac] form:
@RACKETBLOCK[
define-syntax (ntac stx)
  syntax-case stx ()
    [(_ goal . script) (ntac-interp #'goal #'script)]
]
The @racket[ntac] form runs, at compile-time, the metalanguage function
@racket[ntac-interp] to generate an object language term.
The function @racket[ntac-interp] takes syntax representing an object language type,
@racket[#'goal] and syntax representing a sequence of tactics,
@racket[#'script].

In ntac, we use proof trees @racket[ntt] to represent partial terms in the
object language with multiple holes and contextual information such as
assumptions, and then use the ntac proof tree zipper @racket[nttz] to navigate
the tree and focus on a particular goal.
Tactics are metalanguage functions on @racket[nttz]s.
We will not discuss this design or these data structures in more details here;
the design is described in the Cur documentation.

Since tactics are just metalanguage functions, we can create syntactic sugar
for defining tactics as follows:
@racketblock[
define-syntax $ define-tactic syn
  syntax-rules ()
    [(_ e ...)
     (begin-for-syntax
       (define e ...))]
]
The form @racket[define-tactic] is simply a wrapper for conveniently
defining a new metalanguage function.
Note that this extension generates metalanguage code, by generating a new
metalanguage block containing a metalanguage definition.
Until now, we have only seen extensions that compute using the metalanguage and
generate code in object language, but recall from @secref{sec:cur} that Cur
supports an infinite hierarchy of language extension.

Now let us write the tactic script interpreter.
We begin by defining the function @racket[run-tactic], which takes a proof
tree zipper and a syntax object representing a call to a tactic.
@racketblock[
begin-for-syntax
  define $ run-tactic nttz tactic-stx
    define tactic $ eval tactic-stx
    tactic nttz
]
We use @racket[eval] to evaluate the syntax representing the function name and
get a function value.
Then we simply apply the tactic to the proof tree zipper.

Finally, we define @racket[ntac-interp] to interpret a tactic script and solve a goal.
@racketblock[
begin-for-syntax
  define $ ntac-interp goal script
    define pt $ new-proof-tree $ cur-expand goal
    define last-nttz
      for/fold ([nttz (make-nttz pt)])
               ([tactic-stx (syntax->list script)])
        run-tactic nttz tactic-stx
    proof-tree->term $ finish-nttz last-nttz
]
We begin by generating a fresh proof tree which starts with one goal.
The @racket[for/fold] form folds @racket[run-tactic] over the list of tactic
calls with a starting proof tree zipper over the initial proof tree.
After running all tactics, we check that the proof has no goals left, then
generate a term from the proof tree.

Many operations work directly on the current proof tree, so it is cumbersome to define each
tactic by first extracting the proof tree from the proof tree zipper.
We introduce a notion of @emph{tacticals}, metalanguage functions that take a
context and a proof tree and return a new proof tree.
We define a tactic @racket[fill] to take a tactical and apply it at the focus of the proof tree zipper.
With a notion of tacticals, we can easily define the tactical @racket[intro] as follows:
@RACKETBLOCK[
define-tactical ((intro [name #f]) env pt)
  define $ ntt-goal pt
  ntac-match goal
   [(forall (x : P) body)
    define the-name (syntax->datum (or name #'x))
    make-ntt-apply
     goal
     λ (body-pf)
       #`(λ (#,the-name : P) #,body-pf)
     list
      make-ntt-env
       λ (old-env)
         (hash-set old-env the-name #'P)
       make-ntt-hole #'body]
]
We define a new tactical @racket[intro], which takes one optional argument from
the user @racket[name], and will be provided the local environment and proof
tree from the ntac interpreter.
In @racket[intro], we start by extracting the current goal from the proof tree.
To pattern match on the goal we use the form @racket[ntac-match], a simple
wrapper around the Racket @racket[match] form that hides some boilerplate such
as expanding the goal into a Curnel form and raising an exception if no
patterns match.
If the goal has the form of a dependent function type, we make a new node in
the ntac proof tree that solves goal by taking a solution for the type of the
body of the function and building a lambda expression in the object language.
This node contains a subtree that makes the solution of @racket[#'body] the new
goal and adds the assumption that @racket[name] has type @racket[P] in the
scope of this new goal.

To make the @racket[intro] tactical easier to use at the top level, we define
the @racket[by-intro] tactic:
@racketblock[
begin-for-syntax
  define-syntax $ by-intro syn
    syntax-case syn ()
      [_
       #`(fill (intro))]
      [(_ name)
       #`(fill (intro #'name))]
]
We create a metalanguage macro @racket[by-intro] that takes a name as an
optional argument.
This macro expands to an application of the @racket[fill] tactic to the @racket[intro] tactical.
We define @racket[by-intro] as a macro so the user can enter a name for the
assumption as a raw symbol, like @racket[(by-intro A)], rather than as a syntax
object like @racket[(by-intro #'A)].

Since tactics are arbitrary metalanguage functions, we can define tactics in
terms of other tactics, define recursive tactics, and even call to external
programs or solvers in the metalanguage or even through the foreign-function
interface of our metalanguage.
Our next tactic, @racket[by-obvious], demonstrates these first two features.
It will solve any theorem that follows immediately from its premises.

@racketblock[
define-tactical $ obvious env pt
  ntac-match $ ntt-goal pt
    [(forall (a : P) body)
     ((intro) env pt)]
    [a:id
     (assumption env pt)]

define-tactic $ by-obvious ptz
  define nptz $ (fill obvious) ptz
  if $ nttz-done? nptz
      nptz
      by-obvious nptz
]
First we define the @racket[obvious] tactical, which simply matches a goal and
uses either @racket[intro] or @racket[assumption] to solve it.
Then we define the @racket[by-obvious] tactic which fills the hole using the
@racket[obvious] tactical and recurs until there are no goals left.

As we have the entire metalanguage available, we can define sophisticated
tactics that do arbitrary metalanguage computation.
For instance, since our metalanguage provides I/O and reflection, we can define
interactivity as a user-defined tactic.
We begin implementing interactive by first implementing the @racket[print]
tactic.
This tactic will print the state of the focus of the proof tree zipper and return it unmodified.
@racketblock[
define-tactic $ print ptz
  match $ nttz-focus ptz
    [(ntt-hole _ goal)
     for ([(k v) (in-hash (nttz-context tz))])
       printf "~a : ~a\n" k (syntax->datum v)
     printf "-----------------------------\n"
     printf "~a\n\n" (syntax->datum goal)]
    [(ntt-done _ _ _)
     printf "Proof complete.\n"]
  ptz
]
We first match on the focus of proof tree zipper. If there is a goal, then we
print all assumptions in the context followed by a horizontal line and the
current goal.
If the zipper indicates the proof has no goals left, then we simply print
"Proof Complete".

Now we define the @racket[interactive] tactic.
This tactic uses the @racket[print] tactic to print the proof state, then
starts a read-eval-print-loop (REPL).
@racketblock[
define-tactic $ interactive ptz
  print ptz
  let ([cmd (read-syntax)])
    syntax-case cmd (quit)
      [(quit) ....]
      [tactic
       (define ntz (run-tactic ptz tactic))
       (interactive ntz)]
]
The REPL reads in a command and runs it via @racket[run-tactics] if it is a
tactic.
The REPL also accepts @racket[quit] as a command that exits the REPL 
and returns the final proof state.

Now we have defined not only a user-defined tactic system, but a user-defined
@emph{interactive} tactic system.
We can use the interactive tactic just like any other tactic:
@racketblock[
ntac $ forall (A : Type) (a : A) A
 interactive
]
The following is a sample session in our interactive tactic:
@racketblock[
——————————–
(forall (A : Type) (forall (a : A) A))

> (by-intro A)
A : Type
——————————–
(forall (a : A) A)

....

> by-assumption
Proof complete.

> (quit)
]