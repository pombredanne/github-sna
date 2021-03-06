/**
 * github-sna
 */
 
/** 
 * Parameters - set default values here; you can override with -p on the command-line.
 */
 
%default INPUT_PATH '/home/mroddy/Desktop/Github-Events-2012-12-10-8.json'
%default OUTPUT_DIR '/home/mroddy/Desktop/github-events-output'
%default CORR_LIMIT '10000000'
%default DECIMALS_TO_ROUND '4'
%declare RND_MLTP 'POW(10, $DECIMALS_TO_ROUND)'

/**
 * User-Defined Functions (UDFs)
 */
REGISTER '../udfs/python/githubsna.py' USING streaming_python AS githubsna;

DEFINE POW org.apache.pig.piggybank.evaluation.math.POW;
DEFINE EXP org.apache.pig.piggybank.evaluation.math.EXP;
DEFINE FLOOR org.apache.pig.piggybank.evaluation.math.FLOOR;


-- This is an example of loading up input data
raw_events = LOAD '$INPUT_PATH'
    USING org.apache.pig.piggybank.storage.JsonLoader('actor:chararray, repository:map[], type:chararray');
filtered_raw_events = FILTER raw_events
    BY (actor is not null) and (repository is not null);

user_repo_events = FOREACH filtered_raw_events GENERATE
    actor as user,
    (repository#'organization' is not null ?
        repository#'organization' : repository#'owner') AS repo_owner,
    repository#'name' AS repo_name,
    type AS event_type;

user_repo_events = FOREACH user_repo_events GENERATE
    user, CONCAT(repo_owner, CONCAT('/', repo_name)) AS repo, event_type;



/* Get the total number of repos present */
repos = FOREACH user_repo_events GENERATE repo;
distinct_repos = DISTINCT repos;
grouped_distinct_repos = GROUP distinct_repos ALL;
repo_count = FOREACH grouped_distinct_repos GENERATE
    COUNT(distinct_repos) AS total_repos;
-- repo_count = FOREACH (GROUP repos all) {
--     GENERATE COUNT_STAR(repos) AS total_repos;
--     };




/* For a better ranking it would could score each event varying by the type
   (a accepted pull request is a stronger interaction than a star), for now
    we score all events as equal to one. */
scored_user_repo_events = FOREACH user_repo_events GENERATE
    user, repo, 1 AS event_score;




/* Score a user's total interaction with each repo they've touched */
user_repo_event_scores = FOREACH (GROUP scored_user_repo_events BY (user, repo)) {
    GENERATE FLATTEN(group) AS (user, repo), SUM(scored_user_repo_events.event_score) AS score;
    };

/* Total number of users that has interacted with each repo */
repo_users = FOREACH (GROUP user_repo_events BY (repo)) {
    unique_users = DISTINCT user_repo_events.user;
    GENERATE FLATTEN(group) AS (repo), COUNT(unique_users) AS user_count;
    };

scores_with_size_join = JOIN user_repo_event_scores BY (repo), repo_users BY (repo);
scores_with_size = FOREACH scores_with_size_join GENERATE
    user_repo_event_scores::user AS user,
    user_repo_event_scores::repo AS repo,
    user_repo_event_scores::score AS score,
    repo_users::user_count AS repo_total_users;

scores_with_size2 = FOREACH scores_with_size GENERATE user, repo, score, repo_total_users;

user_score_pairs = JOIN scores_with_size BY (user), scores_with_size2 BY (user);
user_score_pairs = FILTER user_score_pairs BY scores_with_size::repo > scores_with_size2::repo;


user_score_pairs = FOREACH user_score_pairs GENERATE
    scores_with_size::user AS user,
    scores_with_size::repo AS repo1,
    scores_with_size2::repo AS repo2,
    scores_with_size::score AS score1,
    scores_with_size2::score AS score2,
    scores_with_size::repo_total_users AS repo_total_users1,
    scores_with_size2::repo_total_users AS repo_total_users2;


user_score_pairs_with_stats_measures = FOREACH user_score_pairs GENERATE
    user, repo1, repo2, score1, score2, repo_total_users1, repo_total_users2,
    (score1 * score2) AS rating_product,
    POW(score1, 2) AS score1Sqr,
    POW(score2, 2) AS score2Sqr;
    
repo_pair_agg = FOREACH(GROUP user_score_pairs_with_stats_measures BY (repo1, repo2)) {
    prod_sum = SUM(user_score_pairs_with_stats_measures.rating_product);
    score1_sum = SUM(user_score_pairs_with_stats_measures.score1);
    score2_sum = SUM(user_score_pairs_with_stats_measures.score2);
    score1_normsqr = SUM(user_score_pairs_with_stats_measures.score1Sqr);
    score2_normsqr = SUM(user_score_pairs_with_stats_measures.score2Sqr);

    -- There's probably a better way to do this, just copying from the tutorial for now
    repo_total_users1 = MAX(user_score_pairs_with_stats_measures.repo_total_users1);
    repo_total_users2 = MAX(user_score_pairs_with_stats_measures.repo_total_users2);

    GENERATE FLATTEN(group) AS (repo1, repo2),
        (float)prod_sum AS prod_sum,
        (float)score1_sum AS score1_sum,
        (float)score2_sum AS score2_sum,
        (float)score1_normsqr AS score1_normsqr,
        (float)score2_normsqr AS score2_normsqr,
        (float)repo_total_users1 AS repo_total_users1,
        (float)repo_total_users2 AS repo_total_users2;
};        


repo_correlation = FOREACH repo_pair_agg GENERATE
    repo1, repo2,
    ((((int)repo_count.total_repos) * prod_sum - score1_sum * score2_sum) /
        (SQRT(((int)repo_count.total_repos) * score1_normsqr - score1_sum * score1_sum)
            * SQRT(((int)repo_count.total_repos) * score2_normsqr - score2_sum * score2_sum)) ) AS correlation;

/* repo_correlation score rounded */
repo_correlation_rounded = FOREACH repo_correlation GENERATE
    repo1, repo2, correlation, (FLOOR($RND_MLTP * correlation) / $RND_MLTP) AS rounded_correlation;


/* Distribution of individual scores */
-- Cast score as string for more deterministic grouping, I hope
repo_correlcation_as_str = FOREACH repo_correlation GENERATE
    repo1, repo2, correlation, (chararray)correlation AS correlation_str;
score_distribution = FOREACH (GROUP repo_correlcation_as_str BY (correlation_str)) {
    GENERATE FLATTEN(group) AS correlation, COUNT(repo_correlcation_as_str);
    };

/* Distribution of scores when rounded to decimal place */
rounded_repo_correlcation_as_str = FOREACH repo_correlation_rounded GENERATE
    repo1, repo2, correlation, (chararray)rounded_correlation AS correlation_str;
rounded_score_distribution = FOREACH (GROUP rounded_repo_correlcation_as_str BY (correlation_str)) {
    GENERATE FLATTEN(group) AS (correlation), COUNT(rounded_repo_correlcation_as_str);
    };



sorted_repo_correlation = ORDER repo_correlation BY correlation DESC PARALLEL 4;

limited_repo_correlation = LIMIT sorted_repo_correlation $CORR_LIMIT;

-- remove any existing data
rmf $OUTPUT_DIR

-- store the results
STORE sorted_repo_correlation INTO '$OUTPUT_DIR/sorted_repo_correlation' USING PigStorage(',');
STORE score_distribution INTO '$OUTPUT_DIR/score_distribution' USING PigStorage(',');
STORE rounded_score_distribution INTO '$OUTPUT_DIR/rounded_score_distribution' USING PigStorage(',');
STORE limited_repo_correlation INTO '$OUTPUT_DIR/limited_repo_correlation' USING PigStorage(',');
