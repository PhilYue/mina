/*
 Main.re is the entry point of the leaderboard project.

 Main.re has the responsibilities for querying the archive postgres database for
 all the blockchain data and parsing the rows into blocks.

 Additionally, Main.re expects to have the credentials, spreadsheet id, and postgres
 connection string available in the form of environment variables.  */

let getEnvOrFail = name =>
  switch (Js.Dict.get(Node.Process.process##env, name)) {
  | Some(value) => value
  | None => failwith({j|Couldn't find env var: `$name`|j})
  };

/* The Google Sheets API expects the credentials to be a local file instead of a parameter
       Thus, we set an environment variable indicating it's path.
   */
Node.Process.putEnvVar(
  "GOOGLE_APPLICATION_CREDENTIALS",
  "./google_sheets_credentials.json",
);

let credentials = getEnvOrFail("GOOGLE_APPLICATION_CREDENTIALS");
let spreadsheetId = getEnvOrFail("SPREADSHEET_ID");
let pgConnection = getEnvOrFail("PGCONN");

let main = () => {
  let pool = Postgres.createPool(pgConnection);
  Postgres.makeQuery(pool, Postgres.getLateBlocks, result => {
    switch (result) {
    | Ok(blocks) =>
      let metrics =
        blocks |> Types.Block.parseBlocks |> Metrics.calculateMetrics;

      UploadLeaderboardPoints.uploadChallengePoints(
        spreadsheetId,
        metrics,
        () => {
          UploadLeaderboardData.uploadUserProfileData(spreadsheetId);

          Postgres.makeQuery(pool, Postgres.getBlockHeight, result => {
            switch (result) {
            | Ok(blockHeightQuery) =>
              Belt.Option.(
                Js.Json.(
                  blockHeightQuery[0]
                  ->decodeObject
                  ->flatMap(__x => Js.Dict.get(__x, "max"))
                  ->flatMap(decodeString)
                  ->mapWithDefault((), height => {
                      UploadLeaderboardData.uploadData(spreadsheetId, height)
                    })
                )
              );
              Postgres.endPool(pool);
            | Error(error) => Js.log(error)
            }
          });
        },
      );

    | Error(error) => Js.log(error)
    }
  });
};

main();
