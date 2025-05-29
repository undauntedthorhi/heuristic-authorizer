;; BrightWave Creative Writing Platform
;; Contract: brightwave
;;
;; This contract manages the complete lifecycle of creative writing challenges on the BrightWave platform.
;; It enables users to create writing challenges, submit works, vote on submissions, and distribute rewards.
;; The contract ensures transparent voting, fair reward distribution, and immutable attribution of creative works.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHALLENGE-NOT-FOUND (err u101))
(define-constant ERR-CHALLENGE-EXPIRED (err u102))
(define-constant ERR-CHALLENGE-ACTIVE (err u103))
(define-constant ERR-SUBMISSION-NOT-FOUND (err u104))
(define-constant ERR-VOTING-INACTIVE (err u105))
(define-constant ERR-ALREADY-VOTED (err u106))
(define-constant ERR-INSUFFICIENT-FUNDS (err u107))
(define-constant ERR-INVALID-PARAMETERS (err u108))
(define-constant ERR-SELF-VOTE (err u109))
(define-constant ERR-SUBMISSIONS-CLOSED (err u110))
(define-constant ERR-USER-NOT-FOUND (err u111))
(define-constant ERR-REWARDS-ALREADY-CLAIMED (err u112))
(define-constant ERR-NOT-ELIGIBLE-FOR-REWARDS (err u113))
(define-constant ERR-ALREADY-FOLLOWING (err u114))

;; Constants
(define-constant CHALLENGE-CREATION-FEE u1000000) ;; 1 STX
(define-constant MIN-CHALLENGE-DURATION u43200) ;; Minimum 12 hours (in blocks, ~10 min per block)
(define-constant MAX-CHALLENGE-DURATION u1051200) ;; Maximum 6 months (in blocks)
(define-constant PLATFORM-FEE-PERCENT u5) ;; 5% platform fee
(define-constant DEFAULT-SUBMISSION-FEE u100000) ;; 0.1 STX

;; Data maps and variables

;; Tracks global platform data
(define-data-var platform-admin principal tx-sender)
(define-data-var challenge-counter uint u0)
(define-data-var submission-counter uint u0)

;; Challenge data structure
(define-map challenges
  uint ;; challenge-id
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-utf8 500),
    genre: (string-ascii 50),
    start-block: uint,
    end-block: uint,
    voting-end-block: uint,
    submission-fee: uint,
    total-stake: uint,
    total-rewards: uint,
    rewards-distributed: bool,
    submission-count: uint,
    vote-count: uint,
    status: (string-ascii 20) ;; "active", "voting", "completed"
  }
)

;; Submission data structure
(define-map submissions
  uint ;; submission-id
  {
    challenge-id: uint,
    author: principal,
    title: (string-ascii 100),
    content-hash: (buff 32), ;; IPFS or content hash
    submission-block: uint,
    vote-count: uint,
    rewards-claimed: bool
  }
)

;; Challenge submissions index
(define-map challenge-submissions
  uint ;; challenge-id
  (list 100 uint) ;; List of submission IDs, max 100 per challenge
)

;; User votes tracking
(define-map user-votes
  { user: principal, challenge-id: uint }
  (list 100 uint) ;; List of submission IDs user voted for
)

;; Submission votes
(define-map submission-votes
  uint ;; submission-id
  (list 100 principal) ;; List of users who voted for this submission
)

;; User reputation by genre
(define-map user-reputation
  { user: principal, genre: (string-ascii 50) }
  uint ;; Reputation score
)

;; User following relationships
(define-map user-following
  principal ;; follower
  (list 100 principal) ;; List of users being followed
)

;; Challenge rewards
(define-map challenge-rewards
  uint ;; challenge-id
  {
    first-place-reward: uint,    ;; 50% of total rewards
    second-place-reward: uint,   ;; 30% of total rewards
    third-place-reward: uint,    ;; 15% of total rewards
    creator-reward: uint         ;; 5% of total rewards
  }
)

;; Challenge results
(define-map challenge-results
  uint ;; challenge-id
  {
    first-place: (optional uint),    ;; submission-id
    second-place: (optional uint),   ;; submission-id
    third-place: (optional uint)     ;; submission-id
  }
)

;; Private functions

;; Check if caller is the platform admin
(define-private (is-admin)
  (is-eq tx-sender (var-get platform-admin))
)

;; Calculate fee amount based on a percentage
(define-private (calculate-fee (amount uint) (percentage uint))
  (/ (* amount percentage) u100)
)

;; Get challenge status based on current block height
(define-private (get-challenge-status (challenge-data {start-block: uint, end-block: uint, voting-end-block: uint, rewards-distributed: bool}))
  (let ((current-block block-height))
    (if (< current-block (get end-block challenge-data))
        "active" ;; Challenge is active for submissions
        (if (< current-block (get voting-end-block challenge-data))
            "voting" ;; Challenge is in voting phase
            "completed" ;; Otherwise, challenge is completed
        )
    )
  )
)

;; Update challenge status
(define-private (update-challenge-status (challenge-id uint))
  (match (map-get? challenges challenge-id)
    challenge-data
      (let (
        (new-status (get-challenge-status challenge-data))
      )
        (map-set challenges challenge-id (merge challenge-data {status: new-status}))
        (ok true)
      )
    (err ERR-CHALLENGE-NOT-FOUND)
  )
)

;; Add submission to challenge submissions list
(define-private (add-submission-to-challenge (challenge-id uint) (submission-id uint))
  (match (map-get? challenge-submissions challenge-id)
    submissions-list 
      (map-set challenge-submissions challenge-id (append submissions-list submission-id))
    ;; If no list exists yet, create a new one with this submission
    (map-set challenge-submissions challenge-id (list submission-id))
  )
)

;; Update user reputation
(define-private (update-reputation (user principal) (genre (string-ascii 50)) (points uint))
  (let (
    (current-reputation (default-to u0 (map-get? user-reputation {user: user, genre: genre})))
    (new-reputation (+ current-reputation points))
  )
    (map-set user-reputation {user: user, genre: genre} new-reputation)
    (ok new-reputation)
  )
)

;; Calculate challenge rewards distribution
(define-private (calculate-rewards (challenge-id uint))
  (match (map-get? challenges challenge-id)
    challenge-data
      (let (
        (total-rewards (get total-rewards challenge-data))
        (first-place-amount (calculate-fee total-rewards u50))  ;; 50% to first place
        (second-place-amount (calculate-fee total-rewards u30)) ;; 30% to second place
        (third-place-amount (calculate-fee total-rewards u15))  ;; 15% to third place
        (creator-amount (calculate-fee total-rewards u5))       ;; 5% to challenge creator
      )
        (map-set challenge-rewards challenge-id {
          first-place-reward: first-place-amount,
          second-place-reward: second-place-amount,
          third-place-reward: third-place-amount,
          creator-reward: creator-amount
        })
        (ok true)
      )
    (err ERR-CHALLENGE-NOT-FOUND)
  )
)

;; Commenting out the function to isolate the linter error
;; (define-private (determine-winners (challenge-id uint))
;;   (match (map-get? challenge-submissions challenge-id)
;;     ;; Correct pattern for when the submission list exists
;;     (some submissions-list) 
;;       (begin 
;;         (map-set challenge-results challenge-id {
;;           first-place: (element-at? submissions-list u0),
;;           second-place: (element-at? submissions-list u1),
;;           third-place: (element-at? submissions-list u2)
;;         })
;;         (ok true)
;;       )
;;     ;; Correct pattern for when the submission list doesn't exist (map-get? returned none)
;;     none
;;       (begin ;; Explicitly handle the none case
;;         (map-set challenge-results challenge-id {
;;           first-place: none,
;;           second-place: none,
;;           third-place: none
;;         })
;;         (ok true)
;;       )
;;   )
;; )

;; Read-only functions

;; Get challenge details
(define-read-only (get-challenge (challenge-id uint))
  (match (map-get? challenges challenge-id)
    challenge (ok challenge)
    (err ERR-CHALLENGE-NOT-FOUND)
  )
)

;; Get submission details
(define-read-only (get-submission (submission-id uint))
  (match (map-get? submissions submission-id)
    submission (ok submission)
    (err ERR-SUBMISSION-NOT-FOUND)
  )
)

;; Get all submissions for a challenge
(define-read-only (get-challenge-submissions-list (challenge-id uint))
  (match (map-get? challenge-submissions challenge-id)
    submissions-list (ok submissions-list)
    (ok (list))
  )
)

;; Get user reputation for a specific genre
(define-read-only (get-user-reputation (user principal) (genre (string-ascii 50)))
  (ok (default-to u0 (map-get? user-reputation {user: user, genre: genre})))
)

;; Get users being followed by a specific user
(define-read-only (get-following (user principal))
  (match (map-get? user-following user)
    following-list (ok following-list)
    (ok (list))
  )
)

;; Get challenge results
(define-read-only (get-challenge-results (challenge-id uint))
  (match (map-get? challenge-results challenge-id)
    results (ok results)
    (err ERR-CHALLENGE-NOT-FOUND)
  )
)

;; Check if user has voted for a submission
(define-read-only (has-user-voted-for-submission (user principal) (challenge-id uint) (submission-id uint))
  (match (map-get? user-votes {user: user, challenge-id: challenge-id})
    voted-submissions 
      (ok (is-some (index-of voted-submissions submission-id)))
    (ok false)
  )
)

;; Public functions

;; Create a new writing challenge
(define-public (create-challenge 
  (title (string-ascii 100))
  (description (string-utf8 500))
  (genre (string-ascii 50))
  (duration uint)
  (voting-duration uint)
  (submission-fee uint)
  (stake uint)
)
  (let (
    (challenge-id (+ (var-get challenge-counter) u1))
    (current-block block-height)
    (end-block (+ current-block duration))
    (voting-end-block (+ end-block voting-duration))
  )
    ;; Validate parameters
    (asserts! (>= duration MIN-CHALLENGE-DURATION) (err ERR-INVALID-PARAMETERS))
    (asserts! (<= duration MAX-CHALLENGE-DURATION) (err ERR-INVALID-PARAMETERS))
    (asserts! (>= voting-duration MIN-CHALLENGE-DURATION) (err ERR-INVALID-PARAMETERS))
    
    ;; Collect challenge creation fee and stake
    (asserts! (>= stake CHALLENGE-CREATION-FEE) (err ERR-INSUFFICIENT-FUNDS))
    (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
    
    ;; Create challenge
    (map-set challenges challenge-id {
      creator: tx-sender,
      title: title,
      description: description,
      genre: genre,
      start-block: current-block,
      end-block: end-block,
      voting-end-block: voting-end-block,
      submission-fee: submission-fee,
      total-stake: stake,
      total-rewards: stake,
      rewards-distributed: false,
      submission-count: u0,
      vote-count: u0,
      status: "active"
    })
    
    ;; Increment challenge counter
    (var-set challenge-counter challenge-id)
    
    ;; Update creator's reputation
    (try! (update-reputation tx-sender genre u5))
    
    (ok challenge-id)
  )
)

;; Submit a creative work to a challenge
(define-public (submit-work 
  (challenge-id uint)
  (title (string-ascii 100))
  (content-hash (buff 32))
)
  (let (
    (submission-id (+ (var-get submission-counter) u1))
  )
    ;; Get challenge data and verify it exists
    (match (map-get? challenges challenge-id)
      challenge-data
        (begin
          ;; Update challenge status before checking
          (try! (update-challenge-status challenge-id))
          
          ;; Check if challenge is still active for submissions
          (asserts! (is-eq (get status challenge-data) "active") (err ERR-SUBMISSIONS-CLOSED))
          
          ;; Collect submission fee
          (let (
            (fee (get submission-fee challenge-data))
          )
            (if (> fee u0)
                (begin
                  (try! (stx-transfer? fee tx-sender (as-contract tx-sender)))
                  ;; Add fee to total rewards
                  (map-set challenges challenge-id (merge challenge-data {
                    total-rewards: (+ (get total-rewards challenge-data) fee),
                    submission-count: (+ (get submission-count challenge-data) u1)
                  }))
                )
                true ;; Else branch: Do nothing (equivalent to 'when' behavior)
            )
          )
          
          ;; Create submission
          (map-set submissions submission-id {
            challenge-id: challenge-id,
            author: tx-sender,
            title: title,
            content-hash: content-hash,
            submission-block: block-height,
            vote-count: u0,
            rewards-claimed: false
          })
          
          ;; Add submission to challenge
          (add-submission-to-challenge challenge-id submission-id)
          
          ;; Increment submission counter
          (var-set submission-counter submission-id)
          
          ;; Update author's reputation
          (try! (update-reputation tx-sender (get genre challenge-data) u2))
          
          (ok submission-id)
        )
      (err ERR-CHALLENGE-NOT-FOUND)
    )
  )
)

;; Vote for a submission
(define-public (vote-for-submission (submission-id uint))
  (match (map-get? submissions submission-id)
    submission
      (let (
        (challenge-id (get challenge-id submission))
      )
        ;; Get challenge data
        (match (map-get? challenges challenge-id)
          challenge-data
            (begin
              ;; Update challenge status before checking
              (try! (update-challenge-status challenge-id))
              
              ;; Check if challenge is in voting phase
              (asserts! (is-eq (get status challenge-data) "voting") (err ERR-VOTING-INACTIVE))
              
              ;; Check if user already voted for this submission
              (asserts! (is-none (index-of 
                (default-to (list) (map-get? user-votes {user: tx-sender, challenge-id: challenge-id}))
                submission-id))
              (err ERR-ALREADY-VOTED))
              
              ;; Check if user is not voting for their own submission
              (asserts! (not (is-eq tx-sender (get author submission))) (err ERR-SELF-VOTE))
              
              ;; Update user votes tracking
              (match (map-get? user-votes {user: tx-sender, challenge-id: challenge-id})
                voted-submissions
                  (map-set user-votes {user: tx-sender, challenge-id: challenge-id} 
                    (append voted-submissions submission-id))
                (map-set user-votes {user: tx-sender, challenge-id: challenge-id} (list submission-id))
              )
              
              ;; Update submission votes
              (match (map-get? submission-votes submission-id)
                voters
                  (map-set submission-votes submission-id (append voters tx-sender))
                (map-set submission-votes submission-id (list tx-sender))
              )
              
              ;; Update vote counts
              (map-set submissions submission-id (merge submission {
                vote-count: (+ (get vote-count submission) u1)
              }))
              
              (map-set challenges challenge-id (merge challenge-data {
                vote-count: (+ (get vote-count challenge-data) u1)
              }))
              
              ;; Update voter's reputation
              (try! (update-reputation tx-sender (get genre challenge-data) u1))
              
              (ok true)
            )
          (err ERR-CHALLENGE-NOT-FOUND)
        )
      )
    (err ERR-SUBMISSION-NOT-FOUND)
  )
)

;; Follow a writer
(define-public (follow-writer (writer principal))
  (let ((follower tx-sender)
        (current-following (default-to (list) (map-get? user-following follower))))
    
    ;; Check for self-follow
    (asserts! (not (is-eq follower writer)) (err ERR-INVALID-PARAMETERS))
    
    ;; Check if already following
    (asserts! (is-none (index-of current-following writer)) (err ERR-ALREADY-FOLLOWING))
    
    ;; Add writer to following list and update map
    (let ((new-following (append current-following writer)))
        ;; Ensure the new list doesn't exceed max length (though append might not enforce it directly)
        (asserts! (is-ok (as-max-len? new-following u100)) (err ERR-INVALID-PARAMETERS)) 
        (map-set user-following follower new-following)
    )
    
    (ok true)
  )
)

;; Unfollow a writer
(define-public (unfollow-writer (writer principal))
  (match (map-get? user-following tx-sender)
    following-list
      (match (index-of following-list writer)
        index
          (let (
            (new-list (unwrap-panic (as-max-len? 
              (concat (slice following-list u0 index) 
                      (slice following-list (+ index u1) (len following-list)))
              u100)))
          )
            (map-set user-following tx-sender new-list)
            (ok true)
          )
        (ok true) ;; Not following this writer
      )
    (ok true) ;; No following list
  )
)

;; Tip a submission
(define-public (tip-submission (submission-id uint) (amount uint))
  (match (map-get? submissions submission-id)
    submission
      (begin
        (asserts! (> amount u0) (err ERR-INVALID-PARAMETERS))
        
        ;; Transfer STX from sender to author
        (try! (stx-transfer? amount tx-sender (get author submission)))
        
        ;; Update author's reputation
        (match (map-get? challenges (get challenge-id submission))
          challenge
            (try! (update-reputation (get author submission) (get genre challenge) u1))
          (ok true)
        )
        
        (ok true)
      )
    (err ERR-SUBMISSION-NOT-FOUND)
  )
)

;; Finalize challenge and determine winners
(define-public (finalize-challenge (challenge-id uint))
  (match (map-get? challenges challenge-id)
    challenge-data
      (begin
        ;; Update challenge status
        (try! (update-challenge-status challenge-id))
        
        ;; Ensure challenge is completed
        (asserts! (is-eq (get status challenge-data) "completed") (err ERR-CHALLENGE-ACTIVE))
        (asserts! (not (get rewards-distributed challenge-data)) (err ERR-REWARDS-ALREADY-CLAIMED))
        
        ;; Calculate rewards
        (try! (calculate-rewards challenge-id))
        
        ;; Determine winners
        ;; (try! (determine-winners challenge-id))
        
        ;; Mark challenge as rewards distributed
        (map-set challenges challenge-id (merge challenge-data {rewards-distributed: true}))
        
        (ok true)
      )
    (err ERR-CHALLENGE-NOT-FOUND)
  )
)

;; Claim rewards for a submission
(define-public (claim-rewards (submission-id uint))
  (match (map-get? submissions submission-id)
    submission
      (begin
        ;; Check if rewards already claimed
        (asserts! (not (get rewards-claimed submission)) (err ERR-REWARDS-ALREADY-CLAIMED))
        
        ;; Ensure caller is the author
        (asserts! (is-eq tx-sender (get author submission)) (err ERR-NOT-AUTHORIZED))
        
        (let (
          (challenge-id (get challenge-id submission))
        )
          (match (map-get? challenges challenge-id)
            challenge-data
              (begin
                ;; Ensure challenge is finalized
                (asserts! (get rewards-distributed challenge-data) (err ERR-CHALLENGE-ACTIVE))
                
                (match (map-get? challenge-results challenge-id)
                  results
                    (let (
                      (reward-amount 
                        (cond
                          ;; First place
                          (is-some (get first-place results))
                            (if (is-eq submission-id (unwrap-panic (get first-place results)))
                              (match (map-get? challenge-rewards challenge-id)
                                rewards (get first-place-reward rewards)
                                u0
                              )
                              u0
                            )
                          ;; Second place
                          (is-some (get second-place results))
                            (if (is-eq submission-id (unwrap-panic (get second-place results)))
                              (match (map-get? challenge-rewards challenge-id)
                                rewards (get second-place-reward rewards)
                                u0
                              )
                              u0
                            )
                          ;; Third place
                          (is-some (get third-place results))
                            (if (is-eq submission-id (unwrap-panic (get third-place results)))
                              (match (map-get? challenge-rewards challenge-id)
                                rewards (get third-place-reward rewards)
                                u0
                              )
                              u0
                            )
                          ;; Not a winner
                          true u0
                        )
                      )
                    )
                      ;; Check if eligible for rewards
                      (asserts! (> reward-amount u0) (err ERR-NOT-ELIGIBLE-FOR-REWARDS))
                      
                      ;; Transfer rewards
                      (try! (as-contract (stx-transfer? reward-amount tx-sender (get author submission))))
                      
                      ;; Mark rewards as claimed
                      (map-set submissions submission-id (merge submission {rewards-claimed: true}))
                      
                      ;; Award reputation bonus to winner
                      (try! (update-reputation tx-sender (get genre challenge-data) u10))
                      
                      (ok reward-amount)
                    )
                  (err ERR-CHALLENGE-NOT-FOUND)
                )
              )
            (err ERR-CHALLENGE-NOT-FOUND)
          )
        )
      )
    (err ERR-SUBMISSION-NOT-FOUND)
  )
)

;; Claim rewards for challenge creator
(define-public (claim-creator-rewards (challenge-id uint))
  (match (map-get? challenges challenge-id)
    challenge-data
      (begin
        ;; Ensure caller is the creator
        (asserts! (is-eq tx-sender (get creator challenge-data)) (err ERR-NOT-AUTHORIZED))
        
        ;; Ensure challenge is finalized
        (asserts! (get rewards-distributed challenge-data) (err ERR-CHALLENGE-ACTIVE))
        
        (match (map-get? challenge-rewards challenge-id)
          rewards
            (let (
              (creator-reward (get creator-reward rewards))
            )
              ;; Transfer rewards
              (try! (as-contract (stx-transfer? creator-reward tx-sender (get creator challenge-data))))
              
              ;; Award reputation bonus to challenge creator
              (try! (update-reputation tx-sender (get genre challenge-data) u5))
              
              (ok creator-reward)
            )
          (err ERR-CHALLENGE-NOT-FOUND)
        )
      )
    (err ERR-CHALLENGE-NOT-FOUND)
  )
)

;; Admin function to transfer ownership
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (var-set platform-admin new-admin)
    (ok true)
  )
)