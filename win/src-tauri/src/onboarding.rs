//! First-run tour of the Windows app: microphone → engine → done. The Mac tour
//! (`app/Sources/SezishCore/Onboarding.swift`) without Accessibility, which the
//! low-level keyboard hook does not need. Model with invariants and witnesses:
//! `specs/tla/WinOnboarding.tla`; its header maps each action here.

#[cfg(test)]
mod tests {
    use super::{Effect, Engine, Flow, Input, Microphone, Model, Row, Step};

    fn flow(mic: Microphone, engine: Engine, model: Model) -> Flow {
        Flow::new(mic, engine, model, true)
    }

    #[test]
    fn the_tour_skips_a_microphone_that_is_already_on() {
        assert_eq!(flow(Microphone::Granted, Engine::Cloud, Model::Missing).step(), Step::Engine);
        assert_eq!(flow(Microphone::Denied, Engine::Cloud, Model::Missing).step(), Step::Microphone);
        assert_eq!(
            flow(Microphone::Undetermined, Engine::Cloud, Model::Missing).step(),
            Step::Microphone
        );
    }

    /// AskMic / OpenMicSettings: an unanswered microphone is probed so Windows asks;
    /// a refused one only Settings can turn back on.
    #[test]
    fn granting_the_microphone_asks_windows_or_opens_privacy_settings() {
        let mut undetermined = flow(Microphone::Undetermined, Engine::Cloud, Model::Missing);
        assert_eq!(undetermined.row(), Row::Todo);
        assert_eq!(undetermined.on(Input::GrantMicrophone), Effect::RequestMicrophone);
        assert_eq!(undetermined.row(), Row::Waiting);

        let mut denied = flow(Microphone::Denied, Engine::Cloud, Model::Missing);
        assert_eq!(denied.row(), Row::Denied);
        assert_eq!(denied.on(Input::GrantMicrophone), Effect::OpenMicrophoneSettings);
        assert_eq!(denied.row(), Row::Waiting);
    }

    /// Advance: the switch turning on moves the tour after a beat, so the check is seen.
    #[test]
    fn a_granted_microphone_advances_after_a_beat() {
        let mut tour = flow(Microphone::Denied, Engine::Cloud, Model::Missing);
        tour.on(Input::GrantMicrophone);
        assert_eq!(tour.on(Input::Status(Microphone::Granted)), Effect::AdvanceSoon);
        assert_eq!(tour.row(), Row::Ready);
        assert_eq!(tour.step(), Step::Microphone);
        assert_eq!(tour.on(Input::Continue), Effect::None);
        assert_eq!(tour.step(), Step::Engine);
        // The next poll does not advance again.
        assert_eq!(tour.on(Input::Status(Microphone::Granted)), Effect::None);
    }

    /// PastMicOnlyWhenGranted: switching the microphone off mid-tour sends the person back.
    #[test]
    fn a_microphone_switched_off_mid_tour_sends_the_person_back() {
        let mut tour = flow(Microphone::Granted, Engine::Cloud, Model::Missing);
        tour.on(Input::Continue);
        assert_eq!(tour.step(), Step::Done);
        tour.on(Input::Status(Microphone::Denied));
        assert_eq!(tour.step(), Step::Microphone);
        // And Continue cannot skip past it.
        tour.on(Input::Continue);
        assert_eq!(tour.step(), Step::Microphone);
    }

    /// AtMostOneDownload, AutoDownload: choosing local starts the model once.
    #[test]
    fn the_local_engine_starts_one_download() {
        let mut tour = flow(Microphone::Granted, Engine::Cloud, Model::Missing);
        assert_eq!(tour.on(Input::ChooseEngine(Engine::Local)), Effect::DownloadModel);
        assert_eq!(tour.on(Input::ChooseEngine(Engine::Local)), Effect::None);
        assert_eq!(tour.on(Input::Status(Microphone::Granted)), Effect::None);
        assert!(matches!(tour.model(), Model::Downloading(_)));
    }

    #[test]
    fn a_local_engine_without_its_model_downloads_on_any_screen() {
        let mut tour = flow(Microphone::Denied, Engine::Local, Model::Missing);
        assert_eq!(tour.on(Input::Status(Microphone::Denied)), Effect::DownloadModel);
        assert_eq!(tour.on(Input::Model(Model::Downloading(0.4))), Effect::None);
    }

    #[test]
    fn a_failed_download_is_retried_by_the_person() {
        let mut tour = flow(Microphone::Granted, Engine::Local, Model::Failed);
        assert_eq!(tour.on(Input::Status(Microphone::Granted)), Effect::None);
        assert_eq!(tour.on(Input::RetryDownload), Effect::DownloadModel);
        assert_eq!(tour.on(Input::RetryDownload), Effect::None);
    }

    /// FinishOnlyWhenReady.
    #[test]
    fn done_closes_the_tour_only_when_dictation_can_work() {
        let mut tour = flow(Microphone::Granted, Engine::Local, Model::Downloading(0.5));
        tour.on(Input::Continue);
        assert_eq!(tour.step(), Step::Done);
        assert_eq!(tour.on(Input::Continue), Effect::None);
        assert_eq!(tour.step(), Step::Done);

        tour.on(Input::Model(Model::Ready));
        assert_eq!(tour.on(Input::Continue), Effect::Finish);
        assert_eq!(tour.step(), Step::Finished);
        // A finished tour ignores everything.
        assert_eq!(tour.on(Input::Back), Effect::None);
        assert_eq!(tour.step(), Step::Finished);
    }

    #[test]
    fn back_walks_the_screens_in_reverse() {
        let mut tour = flow(Microphone::Granted, Engine::Cloud, Model::Missing);
        tour.on(Input::Continue);
        tour.on(Input::Back);
        assert_eq!(tour.step(), Step::Engine);
        tour.on(Input::Back);
        assert_eq!(tour.step(), Step::Microphone);
        tour.on(Input::Back);
        assert_eq!(tour.step(), Step::Microphone);
    }

    /// CloudBaked = FALSE: the cloud is not offered and cannot be finished on.
    #[test]
    fn a_build_without_the_cloud_runs_the_tour_on_the_local_model() {
        let mut tour = Flow::new(Microphone::Granted, Engine::Cloud, Model::Missing, false);
        assert_eq!(tour.engine(), Engine::Local);
        assert_eq!(tour.on(Input::ChooseEngine(Engine::Cloud)), Effect::None);
        assert_eq!(tour.engine(), Engine::Local);
        assert!(!tour.engine_ready());
    }

    #[test]
    fn the_tour_opens_only_when_dictation_could_not_work_yet() {
        assert!(!Flow::needed(Microphone::Granted, Engine::Cloud, Model::Missing, true));
        assert!(!Flow::needed(Microphone::Granted, Engine::Local, Model::Ready, false));
        assert!(Flow::needed(Microphone::Denied, Engine::Cloud, Model::Ready, true));
        assert!(Flow::needed(Microphone::Undetermined, Engine::Local, Model::Ready, true));
        assert!(Flow::needed(Microphone::Granted, Engine::Local, Model::Missing, true));
        assert!(Flow::needed(Microphone::Granted, Engine::Cloud, Model::Ready, false) == false);
        assert!(Flow::needed(Microphone::Granted, Engine::Cloud, Model::Missing, false));
    }
}
