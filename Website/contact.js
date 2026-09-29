(() => {
  const triggers = document.querySelectorAll("[data-contact-trigger]");

  if (!triggers.length || typeof HTMLDialogElement === "undefined") return;

  const dialog = document.createElement("dialog");
  dialog.className = "contact-dialog";
  dialog.setAttribute("aria-labelledby", "contact-dialog-title");
  dialog.innerHTML = `
    <div class="contact-dialog-content">
      <button class="contact-close" type="button" aria-label="Close contact options">&times;</button>
      <h2 id="contact-dialog-title">Get in touch.</h2>
      <nav class="contact-options" aria-label="Contact options">
        <a href="https://discord.gg/dPEb6Wsfze" target="_blank" rel="noopener noreferrer">
          <span class="contact-option-title">Join the community</span>
          <span class="contact-option-detail contact-option-label">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.317 4.37a19.79 19.79 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.211.375-.445.865-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.618-1.25.077.077 0 0 0-.078-.037A19.74 19.74 0 0 0 3.677 4.37a.07.07 0 0 0-.032.028C.533 9.046-.319 13.58.099 18.058a.082.082 0 0 0 .031.056c2.053 1.508 4.041 2.423 5.993 3.03a.078.078 0 0 0 .084-.028c.462-.63.873-1.295 1.226-1.994a.076.076 0 0 0-.042-.106 12.3 12.3 0 0 1-1.872-.892.077.077 0 0 1-.008-.128c.126-.094.252-.192.372-.291a.074.074 0 0 1 .078-.011c3.928 1.793 8.18 1.793 12.061 0a.074.074 0 0 1 .079.01c.12.1.246.198.373.292a.077.077 0 0 1-.007.128c-.597.342-1.22.644-1.873.891a.077.077 0 0 0-.041.107c.36.698.772 1.363 1.225 1.993a.076.076 0 0 0 .084.029c1.961-.607 3.95-1.522 6.002-3.03a.077.077 0 0 0 .031-.055c.5-5.177-.838-9.674-3.548-13.659a.061.061 0 0 0-.031-.029ZM8.02 15.331c-1.183 0-2.157-1.086-2.157-2.419s.956-2.419 2.157-2.419c1.21 0 2.176 1.095 2.157 2.419 0 1.333-.956 2.419-2.157 2.419Zm7.975 0c-1.183 0-2.157-1.086-2.157-2.419s.956-2.419 2.157-2.419c1.21 0 2.176 1.095 2.157 2.419 0 1.333-.946 2.419-2.157 2.419Z"></path></svg>
            Discord
          </span>
          <span class="contact-option-detail">Discussion, feedback, feature requests, and bug reports</span>
        </a>
        <a href="mailto:support@1234567890.dev">
          <span class="contact-option-title">Support</span>
          <span class="contact-option-detail">Help with Hibiscus and technical issues</span>
          <span class="contact-option-detail">support@1234567890.dev</span>
        </a>
        <a href="mailto:hello@1234567890.dev">
          <span class="contact-option-title">Business &amp; more</span>
          <span class="contact-option-detail">Partnerships, press, and everything else</span>
          <span class="contact-option-detail">hello@1234567890.dev</span>
        </a>
      </nav>
    </div>
  `;

  document.body.append(dialog);

  const closeButton = dialog.querySelector(".contact-close");
  let lastTrigger;
  let isClosing = false;

  const closeDialog = () => {
    if (!dialog.open || isClosing) return;
    isClosing = true;
    dialog.classList.add("is-closing");
    const delay = window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 220;
    window.setTimeout(() => {
      dialog.close();
      dialog.classList.remove("is-closing");
      isClosing = false;
      lastTrigger?.focus();
    }, delay);
  };

  triggers.forEach((trigger) => {
    trigger.addEventListener("click", (event) => {
      event.preventDefault();
      lastTrigger = trigger;
      dialog.showModal();
      closeButton.focus();
    });
  });

  closeButton.addEventListener("click", closeDialog);
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) closeDialog();
  });
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeDialog();
  });
})();
