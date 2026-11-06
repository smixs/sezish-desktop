//! First-run tour of the Windows app: microphone → engine → done. The Mac tour
//! (`app/Sources/SezishCore/Onboarding.swift`) without Accessibility, which the
//! low-level keyboard hook does not need. Model with invariants and witnesses:
//! `specs/tla/WinOnboarding.tla`; its header maps each action here.

use serde::Serialize;

/// Windows' consent for desktop apps to use the microphone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Microphone {
    Undetermined,
    Denied,
    Granted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Engine {
    Cloud,
    Local,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", content = "fraction", rename_all = "snake_case")]
pub enum Model {
    Missing,
    Downloading(f64),
    Ready,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Step {
    Microphone,
    Engine,
    Done,
    Finished,
}

/// The microphone row on the first screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Row {
    Ready,
    /// Not asked yet.
    Todo,
    /// Asked: Windows' prompt or Settings is up. The button reopens it.
    Waiting,
    /// Refused: only Settings can turn it on.
    Denied,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Input {
    Status(Microphone),
    Model(Model),
    GrantMicrophone,
    ChooseEngine(Engine),
    RetryDownload,
    Continue,
    Back,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Effect {
    None,
    /// Open the microphone for a moment so Windows asks.
    RequestMicrophone,
    /// `ms-settings:privacy-microphone`.
    OpenMicrophoneSettings,
    DownloadModel,
    /// The microphone just turned on: move on after a beat, so the check is seen.
    /// The host sends `Continue` then.
    AdvanceSoon,
    /// Close the tour.
    Finish,
}

pub struct Flow {
    step: Step,
    microphone: Microphone,
    engine: Engine,
    model: Model,
    cloud_baked: bool,
    asked_microphone: bool,
    microphone_guide: bool,
}

impl Flow {
    /// `microphone` is read fresh at launch, so a microphone that is already on
    /// skips its screen. A build without the cloud runs on the local model.
    pub fn new(microphone: Microphone, engine: Engine, model: Model, cloud_baked: bool) -> Self {
        Self {
            step: if microphone == Microphone::Granted {
                Step::Engine
            } else {
                Step::Microphone
            },
            microphone,
            engine: if cloud_baked { engine } else { Engine::Local },
            model,
            cloud_baked,
            asked_microphone: false,
            microphone_guide: false,
        }
    }

    /// The tour opens at launch only when dictation could not work yet.
    pub fn needed(microphone: Microphone, engine: Engine, model: Model, cloud_baked: bool) -> bool {
        let flow = Self::new(microphone, engine, model, cloud_baked);
        microphone != Microphone::Granted || !flow.engine_ready()
    }

    pub fn step(&self) -> Step {
        self.step
    }

    pub fn engine(&self) -> Engine {
        self.engine
    }

    pub fn model(&self) -> Model {
        self.model
    }

    pub fn engine_ready(&self) -> bool {
        match self.engine {
            Engine::Cloud => self.cloud_baked,
            Engine::Local => self.model == Model::Ready,
        }
    }

    pub fn row(&self) -> Row {
        match self.microphone {
            Microphone::Granted => Row::Ready,
            Microphone::Denied if self.microphone_guide => Row::Waiting,
            Microphone::Denied => Row::Denied,
            Microphone::Undetermined if self.asked_microphone => Row::Waiting,
            Microphone::Undetermined => Row::Todo,
        }
    }

    pub fn on(&mut self, input: Input) -> Effect {
        if self.step == Step::Finished {
            return Effect::None;
        }
        match input {
            Input::Status(microphone) => self.update(microphone),
            Input::Model(model) => {
                self.model = model;
                self.auto_download()
            }
            Input::GrantMicrophone => self.grant_microphone(),
            Input::ChooseEngine(engine) => {
                let offered = engine == Engine::Local || self.cloud_baked;
                if !matches!(self.step, Step::Engine | Step::Done) || !offered {
                    return Effect::None;
                }
                self.engine = engine;
                if engine == Engine::Local {
                    self.start_download()
                } else {
                    Effect::None
                }
            }
            Input::RetryDownload => {
                if self.engine == Engine::Local && self.model == Model::Failed {
                    self.start_download()
                } else {
                    Effect::None
                }
            }
            Input::Continue => self.primary(),
            Input::Back => {
                self.step = match self.step {
                    Step::Done => Step::Engine,
                    Step::Engine | Step::Microphone => Step::Microphone,
                    Step::Finished => Step::Finished,
                };
                Effect::None
            }
        }
    }

    fn update(&mut self, microphone: Microphone) -> Effect {
        let was_ready = self.microphone == Microphone::Granted;
        self.microphone = microphone;
        let ready = microphone == Microphone::Granted;
        if ready {
            self.microphone_guide = false;
        }
        // Switched off mid-tour: back to the switch.
        if matches!(self.step, Step::Engine | Step::Done) && !ready {
            self.step = Step::Microphone;
        }
        // The download is returned first; the advance waits for `Continue`.
        let download = self.auto_download();
        if download != Effect::None {
            return download;
        }
        if self.step == Step::Microphone && ready && !was_ready {
            return Effect::AdvanceSoon;
        }
        Effect::None
    }

    fn primary(&mut self) -> Effect {
        match self.step {
            Step::Microphone => {
                if self.microphone == Microphone::Granted {
                    self.step = Step::Engine;
                }
            }
            Step::Engine => self.step = Step::Done,
            Step::Done => {
                if self.microphone == Microphone::Granted && self.engine_ready() {
                    self.step = Step::Finished;
                    return Effect::Finish;
                }
            }
            Step::Finished => {}
        }
        Effect::None
    }

    fn grant_microphone(&mut self) -> Effect {
        if self.step != Step::Microphone {
            return Effect::None;
        }
        self.asked_microphone = true;
        match self.microphone {
            Microphone::Granted => Effect::None,
            Microphone::Undetermined => Effect::RequestMicrophone,
            Microphone::Denied => {
                self.microphone_guide = true;
                Effect::OpenMicrophoneSettings
            }
        }
    }

    /// A selected local engine without its model downloads on any screen, so it
    /// runs while the person reads.
    fn auto_download(&mut self) -> Effect {
        if self.engine == Engine::Local && self.model == Model::Missing {
            self.start_download()
        } else {
            Effect::None
        }
    }

    fn start_download(&mut self) -> Effect {
        match self.model {
            Model::Missing | Model::Failed => {
                self.model = Model::Downloading(0.0);
                Effect::DownloadModel
            }
            Model::Downloading(_) | Model::Ready => Effect::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Effect, Engine, Flow, Input, Microphone, Model, Row, Step};

    fn flow(mic: Microphone, engine: Engine, model: Model) -> Flow {
        Flow::new(mic, engine, model, true)
    }

    #[test]
    fn the_tour_skips_a_microphone_that_is_already_on() {
        assert_eq!(
            flow(Microphone::Granted, Engine::Cloud, Model::Missing).step(),
            Step::Engine
        );
        assert_eq!(
            flow(Microphone::Denied, Engine::Cloud, Model::Missing).step(),
            Step::Microphone
        );
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
        assert_eq!(
            undetermined.on(Input::GrantMicrophone),
            Effect::RequestMicrophone
        );
        assert_eq!(undetermined.row(), Row::Waiting);

        let mut denied = flow(Microphone::Denied, Engine::Cloud, Model::Missing);
        assert_eq!(denied.row(), Row::Denied);
        assert_eq!(
            denied.on(Input::GrantMicrophone),
            Effect::OpenMicrophoneSettings
        );
        assert_eq!(denied.row(), Row::Waiting);
    }

    /// Advance: the switch turning on moves the tour after a beat, so the check is seen.
    #[test]
    fn a_granted_microphone_advances_after_a_beat() {
        let mut tour = flow(Microphone::Denied, Engine::Cloud, Model::Missing);
        tour.on(Input::GrantMicrophone);
        assert_eq!(
            tour.on(Input::Status(Microphone::Granted)),
            Effect::AdvanceSoon
        );
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
        assert_eq!(
            tour.on(Input::ChooseEngine(Engine::Local)),
            Effect::DownloadModel
        );
        assert_eq!(tour.on(Input::ChooseEngine(Engine::Local)), Effect::None);
        assert_eq!(tour.on(Input::Status(Microphone::Granted)), Effect::None);
        assert!(matches!(tour.model(), Model::Downloading(_)));
    }

    #[test]
    fn a_local_engine_without_its_model_downloads_on_any_screen() {
        let mut tour = flow(Microphone::Denied, Engine::Local, Model::Missing);
        assert_eq!(
            tour.on(Input::Status(Microphone::Denied)),
            Effect::DownloadModel
        );
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
        assert!(!Flow::needed(
            Microphone::Granted,
            Engine::Cloud,
            Model::Missing,
            true
        ));
        assert!(!Flow::needed(
            Microphone::Granted,
            Engine::Local,
            Model::Ready,
            false
        ));
        assert!(Flow::needed(
            Microphone::Denied,
            Engine::Cloud,
            Model::Ready,
            true
        ));
        assert!(Flow::needed(
            Microphone::Undetermined,
            Engine::Local,
            Model::Ready,
            true
        ));
        assert!(Flow::needed(
            Microphone::Granted,
            Engine::Local,
            Model::Missing,
            true
        ));
        assert!(!Flow::needed(
            Microphone::Granted,
            Engine::Cloud,
            Model::Ready,
            false
        ));
        assert!(Flow::needed(
            Microphone::Granted,
            Engine::Cloud,
            Model::Missing,
            false
        ));
    }
}
