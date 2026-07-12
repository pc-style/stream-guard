const copyButton = document.querySelector("#copy-command");
const command = document.querySelector("#install-command");
const copyStatus = document.querySelector("#copy-status");

copyButton?.addEventListener("click", async () => {
  await navigator.clipboard.writeText(command.textContent.trim());
  copyButton.textContent = "Copied";
  copyStatus.textContent = "paste it into Terminal and press return.";
  window.setTimeout(() => {
    copyButton.textContent = "Copy";
  }, 1600);
});

if (
  window.gsap &&
  window.ScrollTrigger &&
  !window.matchMedia("(prefers-reduced-motion: reduce)").matches
) {
  gsap.registerPlugin(ScrollTrigger);

  gsap.from(".hero-copy > *", {
    opacity: 0,
    y: 28,
    duration: 1,
    stagger: 0.09,
    ease: "power3.out",
  });

  gsap.from(".preview-shell", {
    opacity: 0,
    scale: 0.82,
    rotate: -3,
    duration: 1.2,
    ease: "power3.out",
  });

  gsap.from(".card", {
    scrollTrigger: { trigger: ".bento", start: "top 78%" },
    opacity: 0,
    y: 45,
    scale: 0.94,
    stagger: 0.08,
    duration: 0.8,
    ease: "power3.out",
  });

  const sequenceHeading = document.querySelector("#sequence-heading");
  const sequenceDescription = document.querySelector("#sequence-description");
  const sequencePhases = [
    ["Delay.", "The preview starts black while the stream buffer fills."],
    ["Detect.", "Any sensitive match covers the shared preview immediately."],
    ["Clear.", "Clean checks finish, then PII Guard waits out the full delay."],
    ["Confirm.", "Safe mode keeps the stream black until you approve it."],
  ];

  const showSequencePhase = (index) => {
    const [heading, description] = sequencePhases[index];
    gsap.to([sequenceHeading, sequenceDescription], {
      opacity: 0,
      y: -18,
      duration: 0.18,
      overwrite: true,
      onComplete: () => {
        sequenceHeading.textContent = heading;
        sequenceDescription.textContent = description;
        gsap.fromTo(
          [sequenceHeading, sequenceDescription],
          { opacity: 0, y: 18 },
          { opacity: 1, y: 0, duration: 0.32, stagger: 0.05 },
        );
      },
    });
  };

  document
    .querySelectorAll(".sequence-cards article")
    .forEach((card, index) => {
      ScrollTrigger.create({
        trigger: card,
        start: "top 58%",
        end: "bottom 42%",
        onEnter: () => showSequencePhase(index),
        onEnterBack: () => showSequencePhase(index),
      });

      gsap.from(card, {
        scrollTrigger: {
          trigger: card,
          start: "top 88%",
          end: "top 45%",
          scrub: true,
        },
        opacity: 0.2,
        scale: 0.86,
        y: 70 + index * 8,
      });
    });

  gsap.from(".install-copy > *", {
    scrollTrigger: {
      trigger: ".install",
      start: "top 75%",
      end: "top 40%",
      scrub: true,
    },
    opacity: 0.1,
    y: 25,
    stagger: 0.08,
  });
}
