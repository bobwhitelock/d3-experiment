port module Main exposing (..)

import Date exposing (Date)
import Date.Extra
import DatePicker exposing (DatePicker)
import EveryDict as Dict
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import Json.Decode as D
import Json.Encode as E
import Keyboard
import Maybe.Extra
import Policy
import RemoteData exposing (RemoteData(..), WebData)
import Select
import Tachyons exposing (classes, tachyons)
import Tachyons.Classes as TC exposing (..)
import Tagged
import View
import View.Footer
import View.Vote
import View.VoteEvent
import Vote exposing (Vote)
import VoteEvent exposing (PersonId, VoteEvent)
import Votes exposing (Votes)


-- PORTS --


port chartData : E.Value -> Cmd msg


port chartSettled : (() -> msg) -> Sub msg


port personNodeHovered : (Int -> msg) -> Sub msg


port personNodeUnhovered : (Int -> msg) -> Sub msg


port personNodeClicked : (Int -> msg) -> Sub msg



---- MODEL ----


type alias Model =
    { votes : WebData Votes
    , chartVoteId : Maybe Vote.Id
    , hoveredPersonId : Maybe PersonId
    , selectedPersonId : Maybe PersonId
    , filteredPolicyId : Maybe Policy.Id
    , datePicker : DatePicker
    , personSelectState : Select.State
    , config : Config
    }


type alias Config =
    { apiUrl : String
    }


init : Config -> ( Model, Cmd Msg )
init config =
    let
        ( datePicker, datePickerCmd ) =
            DatePicker.init
    in
    { votes = NotAsked
    , chartVoteId = Nothing
    , hoveredPersonId = Nothing
    , selectedPersonId = Nothing
    , filteredPolicyId = Nothing
    , datePicker = datePicker
    , personSelectState = Select.newState "personSelect"
    , config = config
    }
        ! [ getInitialData config
          , Cmd.map DatePickerMsg datePickerCmd
          ]


getInitialData : Config -> Cmd Msg
getInitialData config =
    let
        url =
            config.apiUrl ++ "/initial-data"
    in
    Http.get url Votes.decoder
        |> RemoteData.sendRequest
        |> Cmd.map InitialDataResponse



---- UPDATE ----


type Msg
    = InitialDataResponse (WebData Votes)
    | VoteEventsResponse Vote.Id (WebData (List VoteEvent))
    | ShowVote Vote.Id
    | KeyPress Int
    | PersonNodeHovered Int
    | PersonNodeUnhovered Int
    | PersonNodeClicked Int
    | ClearSelectedPerson
    | ChartSettled ()
    | FilterByPolicy Policy.Id
    | ClearPolicyFilter
    | SelectPerson (Maybe VoteEvent)
    | PersonSelectMsg (Select.Msg VoteEvent)
    | DatePickerMsg DatePicker.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InitialDataResponse votes ->
            let
                currentVote =
                    case votes of
                        Success votes_ ->
                            Votes.selected votes_

                        _ ->
                            Nothing

                currentVoteDate =
                    Maybe.map .date currentVote

                -- Need to explicitly set date of current Vote in DatePicker,
                -- otherwise will default to current date which may not have a
                -- Vote on it.
                ( newDatePicker, datePickerCmd ) =
                    pickDatePickerDate model currentVoteDate

                ( newModel, initialCmd ) =
                    handleVoteStateChangeWithRestart
                        { model
                            | votes = votes
                            , datePicker = newDatePicker
                        }
            in
            newModel ! [ initialCmd, datePickerCmd ]

        VoteEventsResponse voteId response ->
            case model.votes of
                Success { selected, data, policies } ->
                    let
                        newVotes =
                            Votes selected
                                (Dict.update
                                    voteId
                                    (Maybe.map (\vote -> { vote | voteEvents = response }))
                                    data
                                )
                                policies
                                |> Success

                        newModel =
                            { model | votes = newVotes }
                    in
                    handleVoteStateChangeWithRestart newModel

                _ ->
                    model ! []

        ShowVote newVoteId ->
            showVote model newVoteId

        KeyPress keyCode ->
            case model.votes of
                Success votes ->
                    let
                        maybeShowVote =
                            Maybe.map (.id >> showVote model)
                                >> Maybe.withDefault (model ! [])

                        { previous, next } =
                            Votes.neighbouringVotes model.filteredPolicyId votes
                    in
                    case keyCode of
                        -- Left arrow.
                        37 ->
                            maybeShowVote previous

                        -- Right arrow.
                        39 ->
                            maybeShowVote next

                        _ ->
                            model ! []

                _ ->
                    model ! []

        PersonNodeHovered personId ->
            { model
                | hoveredPersonId = VoteEvent.personId personId |> Just
            }
                ! []

        PersonNodeUnhovered personId ->
            let
                taggedPersonId =
                    VoteEvent.personId personId

                newModel =
                    if model.hoveredPersonId == Just taggedPersonId then
                        { model | hoveredPersonId = Nothing }
                    else
                        model
            in
            newModel ! []

        PersonNodeClicked personId ->
            VoteEvent.personId personId |> selectPerson model

        ClearSelectedPerson ->
            { model | selectedPersonId = Nothing } |> handleVoteStateChangeWithoutRestart

        ChartSettled _ ->
            -- Only request neighbouring vote events, if needed, once we are
            -- informed that the current chart simulation has mostly complete.
            -- If this is done sooner it appears to noticeably interrupt and
            -- slow down the simulation, while waiting for the simulation to
            -- fully complete can take quite a long time; this seems a
            -- reasonable compromise.
            model ! [ getNeighbouringVoteEvents model ]

        FilterByPolicy policyId ->
            { model | filteredPolicyId = Just policyId } ! []

        ClearPolicyFilter ->
            { model | filteredPolicyId = Nothing } ! []

        SelectPerson maybeVoteEvent ->
            case maybeVoteEvent of
                Just voteEvent ->
                    selectPerson model voteEvent.personId

                Nothing ->
                    model ! []

        PersonSelectMsg msg ->
            let
                ( newSelectState, cmd ) =
                    Select.update personSelectConfig msg model.personSelectState
            in
            { model | personSelectState = newSelectState } ! [ cmd ]

        DatePickerMsg msg ->
            case model.votes of
                Success votes ->
                    let
                        ( newDatePicker, datePickerCmd, dateEvent ) =
                            DatePicker.update
                                (datePickerSettings model)
                                msg
                                model.datePicker

                        newSelectedVoteId =
                            case dateEvent of
                                DatePicker.NoChange ->
                                    Votes.selected votes |> Maybe.map .id

                                DatePicker.Changed newDate ->
                                    Maybe.map
                                        (\date ->
                                            Votes.filteredVotesOnDate
                                                model.filteredPolicyId
                                                votes
                                                date
                                                |> List.head
                                        )
                                        newDate
                                        |> Maybe.Extra.join
                                        |> Maybe.map .id

                        ( newVotes, voteChangedCmd ) =
                            case newSelectedVoteId of
                                Just id ->
                                    ( Success { votes | selected = id }
                                    , handleVoteStateChangeWithRestart
                                    )

                                Nothing ->
                                    ( Success votes
                                    , \model -> ( model, Cmd.none )
                                    )

                        ( newModel, newCmd ) =
                            { model
                                | datePicker = newDatePicker
                                , votes = newVotes
                            }
                                |> voteChangedCmd
                    in
                    newModel
                        ! [ Cmd.map DatePickerMsg datePickerCmd
                          , newCmd
                          ]

                _ ->
                    model ! []


showVote : Model -> Vote.Id -> ( Model, Cmd Msg )
showVote model voteId =
    case model.votes of
        Success { data, policies } ->
            let
                newVotes =
                    Votes voteId data policies |> Success

                newModel =
                    { model | votes = newVotes }
            in
            handleVoteStateChangeWithRestart newModel

        _ ->
            model ! []


selectPerson : Model -> PersonId -> ( Model, Cmd Msg )
selectPerson model personId =
    { model | selectedPersonId = Just personId }
        |> handleVoteStateChangeWithoutRestart


handleVoteStateChangeWithRestart : Model -> ( Model, Cmd Msg )
handleVoteStateChangeWithRestart =
    handleVoteStateChange True


handleVoteStateChangeWithoutRestart : Model -> ( Model, Cmd Msg )
handleVoteStateChangeWithoutRestart =
    handleVoteStateChange False


{-|

    Handle in a standard way updating model and making HTTP requests/sending
    graph data through port, when either selected vote or Votes data changes.

-}
handleVoteStateChange : Bool -> Model -> ( Model, Cmd Msg )
handleVoteStateChange restartSimulation model =
    case model.votes of
        Success votes ->
            case Votes.selected votes of
                Just vote ->
                    case vote.voteEvents of
                        Success voteEvents ->
                            { model | chartVoteId = Just vote.id }
                                ! [ sendChartData restartSimulation model.selectedPersonId vote ]

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
                                    Votes
                                        votes.selected
                                        newVotesData
                                        votes.policies
                                        |> Success

                                newModel =
                                    { model | votes = newVotes }
                            in
                            newModel ! [ getEventsForVote model.config vote.id ]

                        Failure _ ->
                            -- XXX Handle this somewhere?
                            model ! []

                        Loading ->
                            model ! []

                Nothing ->
                    model ! []

        _ ->
            model ! []


getNeighbouringVoteEvents : Model -> Cmd Msg
getNeighbouringVoteEvents model =
    case model.votes of
        Success votes ->
            case Votes.selected votes of
                Just vote ->
                    let
                        { previous, next } =
                            Votes.neighbouringVotes model.filteredPolicyId votes

                        maybeCmdToGet =
                            \maybeVote ->
                                Maybe.map (cmdToGetEvents model.config) maybeVote
                                    |> Maybe.Extra.join

                        neighbouringVotesToGet =
                            Maybe.Extra.values
                                [ maybeCmdToGet previous, maybeCmdToGet next ]
                    in
                    Cmd.batch neighbouringVotesToGet

                Nothing ->
                    Cmd.none

        _ ->
            Cmd.none


cmdToGetEvents : Config -> Vote -> Maybe (Cmd Msg)
cmdToGetEvents config vote =
    if RemoteData.isNotAsked vote.voteEvents then
        getEventsForVote config vote.id |> Just
    else
        Nothing


getEventsForVote : Config -> Vote.Id -> Cmd Msg
getEventsForVote config voteId =
    let
        idString =
            Tagged.untag voteId |> toString

        url =
            config.apiUrl ++ "/vote-events/" ++ idString
    in
    Http.get url (D.list VoteEvent.decoder)
        |> RemoteData.sendRequest
        |> Cmd.map (VoteEventsResponse voteId)


sendChartData : Bool -> Maybe PersonId -> Vote -> Cmd msg
sendChartData restartSimulation selectedPersonId vote =
    encodeChartData restartSimulation selectedPersonId vote |> chartData


encodeChartData : Bool -> Maybe PersonId -> Vote -> E.Value
encodeChartData restartSimulation selectedPersonId vote =
    let
        voteEvents =
            Vote.encode selectedPersonId vote
    in
    E.object
        [ ( "voteEvents", voteEvents )
        , ( "restartSimulation", E.bool restartSimulation )
        ]


pickDatePickerDate : Model -> Maybe Date -> ( DatePicker, Cmd Msg )
pickDatePickerDate model date =
    let
        ( newDatePicker, datePickerCmd, dateEvent ) =
            DatePicker.update
                (datePickerSettings model)
                (DatePicker.pick date)
                model.datePicker
    in
    ( newDatePicker
    , Cmd.map DatePickerMsg datePickerCmd
    )


datePickerSettings : Model -> DatePicker.Settings
datePickerSettings { filteredPolicyId, votes } =
    case votes of
        Success votes_ ->
            let
                defaultSettings =
                    DatePicker.defaultSettings

                isDisabled =
                    Votes.filteredVotesOnDate filteredPolicyId votes_
                        >> List.isEmpty

                ( firstYear, lastYear ) =
                    Votes.firstAndLastVoteYears filteredPolicyId votes_
            in
            { defaultSettings
                | isDisabled = isDisabled
                , dateFormatter = Date.Extra.toFormattedString "ddd MMMM, y"
                , inputClassList = [ ( w_100, True ), ( pa1, True ) ]
                , changeYear = DatePicker.between firstYear lastYear
            }

        _ ->
            DatePicker.defaultSettings


personSelectConfig : Select.Config Msg VoteEvent
personSelectConfig =
    let
        classes =
            String.join " "
    in
    Select.newConfig SelectPerson .name
        |> Select.withCutoff 12
        |> Select.withInputWrapperClass mb1
        |> (Select.withInputClass <| classes [ pa1, border_box ])
        |> Select.withItemHtml personSelectItem
        |> (Select.withMenuClass <| classes [ ba, b__gray, bg_white, w_100 ])
        |> Select.withNotFound "No matches"
        |> Select.withNotFoundClass red
        |> Select.withHighlightedItemClass o_50
        -- Hide clear button; not needed.
        |> Select.withClearClass dn
        |> Select.withPrompt "Enter MP to track"



---- VIEW ----


view : Model -> Html Msg
view model =
    case model.votes of
        Success votes ->
            div [] [ page votes model ]

        Failure error ->
            div [] [ "Error loading data: " ++ toString error |> text ]

        NotAsked ->
            div [] []

        Loading ->
            div [] [ text "Loading..." ]


page : Votes -> Model -> Html Msg
page votes model =
    case Votes.selected votes of
        Just current ->
            div
                [ classes
                    [ min_vh_100
                    , mw9
                    , bg_near_white
                    , center
                    , flex
                    , flex_column
                    ]
                ]
                [ tachyons.css
                , visualization current votes model
                , View.Footer.footer
                ]

        _ ->
            div [] [ text "No votes available." ]


visualization : Vote -> Votes -> Model -> Html Msg
visualization currentVote votes model =
    let
        { hoveredPersonId, selectedPersonId, filteredPolicyId } =
            model

        currentEventForPersonId =
            Vote.eventForPersonId currentVote

        hoveredPersonEvent =
            currentEventForPersonId hoveredPersonId

        selectedPersonEvent =
            currentEventForPersonId selectedPersonId

        neighbouringVotes =
            Votes.neighbouringVotes filteredPolicyId votes

        datePicker =
            DatePicker.view
                (Just currentVote.date)
                (datePickerSettings model)
                model.datePicker
                |> Html.map DatePickerMsg
                |> Just

        navigationButtons =
            View.Vote.navigationButtons ShowVote neighbouringVotes
                |> Just
    in
    section
        [ classes
            [ pa3
            , ph5_ns
            , helvetica
            , lh_copy
            , f4
            , overflow_hidden
            , flex_auto
            ]
        ]
        [ div
            [ classes [ fl, w_75 ] ]
            [ currentVoteInfo filteredPolicyId votes currentVote
            , nodeHoveredText hoveredPersonId selectedPersonId
            , View.Vote.chart currentVote
            ]
        , div [ classes [ fl, w_25 ] ]
            [ div [ classes [ fr, w5 ] ]
                (Maybe.Extra.values
                    [ datePicker
                    , navigationButtons
                    , personSelect model currentVote selectedPersonEvent |> Just
                    , selectedPersonInfoBox selectedPersonEvent
                    , hoveredPersonInfoBox hoveredPersonEvent
                    ]
                )
            ]
        ]


currentVoteInfo : Maybe Policy.Id -> Votes -> Vote -> Html Msg
currentVoteInfo filteredPolicyId votes currentVote =
    let
        currentVotePolicies =
            List.map
                (\policyId -> Dict.get policyId votes.policies)
                currentVote.policyIds
                |> Maybe.Extra.values

        policyButtons =
            List.map
                (\policy ->
                    let
                        ( colour, msg, titleText ) =
                            if Just policy.id == filteredPolicyId then
                                ( bg_silver
                                , ClearPolicyFilter
                                , "Currently only showing votes related to this policy; click to show all votes"
                                )
                            else
                                ( View.buttonColour
                                , FilterByPolicy policy.id
                                , "Only show votes related to this policy"
                                )
                    in
                    button
                        [ classes [ colour ]
                        , onClick msg
                        , title titleText
                        ]
                        [ text policy.title ]
                )
                currentVotePolicies
    in
    div
        [ classes [ TC.h4 ] ]
        [ "Current vote: " ++ currentVote.text |> text
        , div [] policyButtons
        ]


nodeHoveredText : Maybe PersonId -> Maybe PersonId -> Html Msg
nodeHoveredText hoveredPersonId selectedPersonId =
    let
        hoveredText =
            Maybe.map
                (\id ->
                    if Just id == selectedPersonId then
                        ""
                    else
                        "Click to Track"
                )
                hoveredPersonId
                |> Maybe.withDefault ""
    in
    div
        [ classes [ w_100, TC.h1, tc, gray ]
        ]
        [ text hoveredText ]


selectedPersonInfoBox : Maybe VoteEvent -> Maybe (Html Msg)
selectedPersonInfoBox =
    View.VoteEvent.maybeInfoBox
        { clearSelectedPersonMsg = ClearSelectedPerson
        , showIcons = True
        }


hoveredPersonInfoBox : Maybe VoteEvent -> Maybe (Html Msg)
hoveredPersonInfoBox =
    View.VoteEvent.maybeInfoBox
        { clearSelectedPersonMsg = ClearSelectedPerson
        , showIcons = False
        }


personSelect : Model -> Vote -> Maybe VoteEvent -> Html Msg
personSelect { personSelectState, selectedPersonId } currentVote selectedPersonEvent =
    let
        voteEvents =
            case currentVote.voteEvents of
                Success voteEvents ->
                    voteEvents

                _ ->
                    []
    in
    Html.map PersonSelectMsg
        (Select.view
            personSelectConfig
            personSelectState
            voteEvents
            selectedPersonEvent
        )


personSelectItem : VoteEvent -> Html Never
personSelectItem voteEvent =
    let
        backgroundColour =
            VoteEvent.partyColour voteEvent

        textColour =
            VoteEvent.partyComplementaryColour voteEvent
    in
    li
        [ style
            [ ( "background-color", backgroundColour )
            , ( "color", textColour )
            ]
        , classes
            [ pa1, bb, b__black, dim, f5, TC.list ]
        ]
        [ text voteEvent.name ]



---- SUBSCRIPTIONS ----


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ personNodeHovered PersonNodeHovered
        , personNodeUnhovered PersonNodeUnhovered
        , personNodeClicked PersonNodeClicked
        , chartSettled ChartSettled
        , Keyboard.ups KeyPress
        ]



---- PROGRAM ----


main : Program Config Model Msg
main =
    Html.programWithFlags
        { view = view
        , init = init
        , update = update
        , subscriptions = subscriptions
        }
