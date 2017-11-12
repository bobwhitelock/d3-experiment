port module Main exposing (..)

import Date exposing (Date)
import Date.Extra
import EveryDict as Dict exposing (EveryDict)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import Json.Decode as D
import Json.Encode as E
import List.Extra
import Maybe.Extra
import RemoteData exposing (RemoteData(..), WebData)
import SelectList exposing (SelectList)
import Svg
import Tachyons exposing (classes, tachyons)
import Tachyons.Classes exposing (..)


-- PORTS --


port chartData : E.Value -> Cmd msg


port personNodeHovered : (Int -> msg) -> Sub msg


chartDataValue : Vote -> E.Value
chartDataValue vote =
    case vote.voteEvents of
        Success events ->
            E.list (List.map voteEventValue events)

        _ ->
            -- XXX Handle this better.
            E.null


voteEventValue : VoteEvent -> E.Value
voteEventValue event =
    E.object
        [ ( "personId", E.int event.personId )
        , ( "name", E.string event.name )
        , ( "partyColour", partyColour event |> E.string )
        , ( "option", toString event.option |> String.toLower |> E.string )
        ]


partyColour : VoteEvent -> String
partyColour event =
    let
        party =
            String.toLower event.party

        labour =
            "#DC241f"
    in
    -- All colours obtained from Wikipedia.
    case party of
        "labour" ->
            labour

        "labour/co-operative" ->
            labour

        "conservative" ->
            "#0087DC"

        "liberal democrat" ->
            "#FAA61A"

        "scottish national party" ->
            "#FEF987"

        "dup" ->
            "#D46A4C"

        "sinn féin" ->
            "#008800"

        "plaid cymru" ->
            "#008142"

        "green" ->
            "#6AB023"

        "speaker" ->
            "black"

        "independent" ->
            "grey"

        unknown ->
            let
                log =
                    Debug.log "Unhandled party: " unknown
            in
            "rebeccapurple"



---- MODEL ----


type alias Model =
    { votes : WebData Votes
    , chartVoteId : Maybe VoteId
    , voteInput : String
    , hoveredPersonId : Maybe Int
    }


type alias Votes =
    { selected : VoteId
    , data : EveryDict VoteId Vote
    }


type alias Vote =
    { id : VoteId
    , policyTitle : String
    , text : String
    , actionsYes : Maybe String
    , actionsNo : Maybe String
    , date : Date
    , voteEvents : WebData (List VoteEvent)
    }


type VoteId
    = VoteId Int


type alias VoteEvent =
    { personId : Int
    , name : String
    , party : String
    , option : VoteOption
    }


type VoteOption
    = Yes
    | No
    | Both
    | Absent


init : ( Model, Cmd Msg )
init =
    ( { votes = NotAsked
      , chartVoteId = Nothing
      , voteInput = ""
      , hoveredPersonId = Nothing
      }
    , getInitialVotes
    )


getInitialVotes : Cmd Msg
getInitialVotes =
    Http.get "/votes" initialVotesDecoder
        |> RemoteData.sendRequest
        |> Cmd.map InitialVotesResponse


getEventsForVote : VoteId -> Cmd Msg
getEventsForVote voteId =
    let
        (VoteId id) =
            voteId

        path =
            "/vote-events/" ++ toString id
    in
    Http.get path (D.list voteEventDecoder)
        |> RemoteData.sendRequest
        |> Cmd.map (VoteEventsResponse voteId)


initialVotesDecoder : D.Decoder Votes
initialVotesDecoder =
    let
        createInitialVotes =
            \( votes, latestVote ) ->
                let
                    -- Every Vote should have a date, but need to filter
                    -- out any which somehow didn't to ensure this.
                    votesWithDates =
                        Maybe.Extra.values votes
                in
                case latestVote of
                    Just latest ->
                        Votes latest.id
                            (createVotesDict votesWithDates
                                |> Dict.insert latest.id latest
                            )
                            |> D.succeed

                    Nothing ->
                        D.fail "Latest vote has no date!"

        createVotesDict =
            \votes ->
                List.map
                    (\vote -> ( vote.id, vote ))
                    votes
                    |> Dict.fromList
    in
    D.map2 (,)
        (D.field "votes" (D.list voteWithoutEventsDecoder))
        (D.field "latestVote" voteWithEventsDecoder)
        |> D.andThen createInitialVotes


voteWithoutEventsDecoder : D.Decoder (Maybe Vote)
voteWithoutEventsDecoder =
    let
        initialVoteState =
            \id ->
                \policyTitle ->
                    \text ->
                        \actionsYes ->
                            \actionsNo ->
                                \date ->
                                    case Date.Extra.fromIsoString date of
                                        Just date_ ->
                                            Vote
                                                id
                                                policyTitle
                                                text
                                                actionsYes
                                                actionsNo
                                                date_
                                                NotAsked
                                                |> Just

                                        Nothing ->
                                            Nothing
    in
    D.map6 initialVoteState
        (D.field "id" D.int |> D.map VoteId)
        (D.field "policy_title" D.string)
        (D.field "text" D.string)
        (D.field "actions_yes" (D.nullable D.string))
        (D.field "actions_no" (D.nullable D.string))
        (D.field "date" D.string)


voteWithEventsDecoder : D.Decoder (Maybe Vote)
voteWithEventsDecoder =
    -- XXX de-duplicate this and above.
    let
        createVote =
            \id ->
                \policyTitle ->
                    \text ->
                        \actionsYes ->
                            \actionsNo ->
                                \date ->
                                    \voteEvents ->
                                        case Date.Extra.fromIsoString date of
                                            Just date_ ->
                                                Vote
                                                    id
                                                    policyTitle
                                                    text
                                                    actionsYes
                                                    actionsNo
                                                    date_
                                                    voteEvents
                                                    |> Just

                                            Nothing ->
                                                Nothing
    in
    D.map7 createVote
        (D.field "id" D.int |> D.map VoteId)
        (D.field "policy_title" D.string)
        (D.field "text" D.string)
        (D.field "actions_yes" (D.nullable D.string))
        (D.field "actions_no" (D.nullable D.string))
        (D.field "date" D.string)
        (D.field "voteEvents" (D.list voteEventDecoder |> D.map Success))


voteEventDecoder : D.Decoder VoteEvent
voteEventDecoder =
    D.map4 VoteEvent
        (D.field "person_id" D.int)
        (D.field "name" D.string)
        (D.field "party" D.string)
        (D.field "option" voteOptionDecoder)


voteOptionDecoder : D.Decoder VoteOption
voteOptionDecoder =
    D.string
        |> D.andThen
            (\option ->
                case option of
                    "aye" ->
                        D.succeed Yes

                    "tellaye" ->
                        D.succeed Yes

                    "no" ->
                        D.succeed No

                    "tellno" ->
                        D.succeed No

                    "both" ->
                        D.succeed Both

                    "absent" ->
                        D.succeed Absent

                    _ ->
                        D.fail ("Unknown vote option: " ++ option)
            )



---- UPDATE ----


type Msg
    = InitialVotesResponse (WebData Votes)
    | VoteEventsResponse VoteId (WebData (List VoteEvent))
    | VoteChanged String
    | ShowVote VoteId
    | PersonNodeHovered Int


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InitialVotesResponse votes ->
            let
                newModel =
                    { model | votes = votes }
            in
            handleVoteStateChange newModel

        VoteEventsResponse voteId response ->
            case model.votes of
                Success { selected, data } ->
                    let
                        newVotes =
                            Votes selected
                                (Dict.update
                                    voteId
                                    (Maybe.map (\vote -> { vote | voteEvents = response }))
                                    data
                                )
                                |> Success

                        newModel =
                            { model | votes = newVotes }
                    in
                    handleVoteStateChange newModel

                _ ->
                    model ! []

        VoteChanged input ->
            { model | voteInput = input } ! []

        ShowVote newVoteId ->
            case model.votes of
                Success { data } ->
                    let
                        newVotes =
                            Votes newVoteId data |> Success

                        newModel =
                            { model | votes = newVotes }
                    in
                    handleVoteStateChange newModel

                _ ->
                    model ! []

        PersonNodeHovered personId ->
            { model | hoveredPersonId = Just personId } ! []


{-|

    Handle in a standard way updating model and making HTTP requests/sending
    graph data through port, when either selected vote or Votes data changes.

-}
handleVoteStateChange : Model -> ( Model, Cmd Msg )
handleVoteStateChange model =
    case model.votes of
        Success votes ->
            case selectedVote votes of
                Just vote ->
                    case vote.voteEvents of
                        Success voteEvents ->
                            ( { model | chartVoteId = Just vote.id }
                            , sendChartData vote
                            )

                        NotAsked ->
                            let
                                newVotesData =
                                    Dict.update
                                        vote.id
                                        (Maybe.map
                                            (\vote -> { vote | voteEvents = Loading })
                                        )
                                        votes.data

                                newVotes =
                                    Votes votes.selected newVotesData |> Success

                                newModel =
                                    { model | votes = newVotes }
                            in
                            newModel ! [ getEventsForVote vote.id ]

                        Failure _ ->
                            -- XXX Handle this somewhere?
                            model ! []

                        Loading ->
                            model ! []

                Nothing ->
                    model ! []

        _ ->
            model ! []


selectedVote : Votes -> Maybe Vote
selectedVote { selected, data } =
    Dict.get selected data


sendChartData : Vote -> Cmd msg
sendChartData vote =
    chartDataValue vote |> chartData


timeOrderedVotes : Votes -> Maybe (SelectList Vote)
timeOrderedVotes { selected, data } =
    -- XXX Remove use of SelectList here; not really necessary?
    let
        compare =
            \vote1 -> \vote2 -> Date.Extra.compare vote1.date vote2.date

        orderedVotes =
            Dict.toList data
                |> List.map Tuple.second
                |> List.sortWith compare
    in
    -- XXX Use SelectList.fromList once exists.
    case ( List.head orderedVotes, List.tail orderedVotes ) of
        ( Just head, Just tail ) ->
            SelectList.fromLists [] head tail
                |> SelectList.select (\vote -> vote.id == selected)
                |> Just

        _ ->
            Nothing


neighbouringVotes : Votes -> Maybe NeighbouringVotes
neighbouringVotes votes =
    case timeOrderedVotes votes of
        Just orderedVotes ->
            let
                previousVote =
                    SelectList.before orderedVotes
                        |> List.reverse
                        |> List.head

                nextVote =
                    SelectList.after orderedVotes
                        |> List.head
            in
            Just
                { previous = previousVote
                , next = nextVote
                }

        Nothing ->
            Nothing


type alias NeighbouringVotes =
    { previous : Maybe Vote
    , next : Maybe Vote
    }



---- VIEW ----


view : Model -> Html Msg
view model =
    case model.votes of
        Success votes ->
            viewVotes model.hoveredPersonId votes

        Failure error ->
            div [] [ "Error loading data: " ++ toString error |> text ]

        NotAsked ->
            div [] []

        Loading ->
            div [] [ text "Loading..." ]


viewVotes : Maybe Int -> Votes -> Html Msg
viewVotes hoveredPersonId votes =
    case ( selectedVote votes, neighbouringVotes votes ) of
        ( Just current, Just { previous, next } ) ->
            let
                previousVoteButton =
                    voteNavigationButton previous "<"

                nextVoteButton =
                    voteNavigationButton next ">"

                voteNavigationButton =
                    \maybeVote ->
                        \icon ->
                            case maybeVote of
                                Just { id } ->
                                    button [ onClick (ShowVote id) ] [ text icon ]

                                Nothing ->
                                    span [] []

                hoveredPersonEvent =
                    case ( current.voteEvents, hoveredPersonId ) of
                        ( Success events, Just personId ) ->
                            List.Extra.find
                                (.personId >> (==) personId)
                                events

                        _ ->
                            Nothing

                hoveredPersonText =
                    case hoveredPersonEvent of
                        Just event ->
                            event.name
                                ++ " | "
                                ++ event.party
                                ++ " | "
                                ++ toString event.option

                        Nothing ->
                            "Nobody"

                chartClasses =
                    if RemoteData.isLoading current.voteEvents then
                        [ o_70 ]
                    else
                        []

                chart =
                    div [ classes chartClasses ]
                        [ Svg.svg
                            [ width 1000
                            , height 800
                            , id "d3-simulation"
                            ]
                            []
                        ]
            in
            div []
                [ tachyons.css
                , div []
                    [ "Current vote: "
                        ++ current.policyTitle
                        ++ " | "
                        ++ current.text
                        ++ " | "
                        ++ Date.Extra.toFormattedString "ddd MMMM, y" current.date
                        |> text
                    ]
                , div [] [ "Hovered over: " ++ hoveredPersonText |> text ]
                , div []
                    [ previousVoteButton, nextVoteButton ]
                , chart
                ]

        _ ->
            div [] [ text "No votes available." ]



---- SUBSCRIPTIONS ----


subscriptions : Model -> Sub Msg
subscriptions model =
    personNodeHovered PersonNodeHovered



---- PROGRAM ----


main : Program Never Model Msg
main =
    Html.program
        { view = view
        , init = init
        , update = update
        , subscriptions = subscriptions
        }
